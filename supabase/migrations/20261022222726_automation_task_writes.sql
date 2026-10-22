-- Candidate write semantics; not applied with the incomplete automation feature.
-- Pure helpers preserve native planning/successor data before the guarded write.
create function taskfold_private.automation_wall_start(task jsonb,input_zone text)
returns timestamptz language plpgsql stable security invoker set search_path='' as $$
declare zone text:=coalesce(nullif(task->>'time_zone',''),input_zone); day date; wall timestamp; wanted timestamp; saved timestamptz;
 offsets numeric[]; offset_seconds numeric; candidate timestamptz; result timestamptz; shift int;
begin
 if zone is null or not exists(select 1 from pg_catalog.pg_timezone_names where name=zone) then return null;end if;
 day:=taskfold_private.automation_civil_day(left(task->>'due_date',10));
 if day is null or coalesce(task->>'due_time','')!~'^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9](\.[0-9]+)?)?$' then return null;end if;
 if ((day::timestamp at time zone zone) at time zone zone)::date<>day then return null;end if;
 wall:=day+left(task->>'due_time',5)::time;
 if coalesce(task->>'time_zone','')<>'' and coalesce(task->>'scheduled_at','')~'^\d{4}-\d{2}-\d{2}T' then
  begin saved:=(task->>'scheduled_at')::timestamptz;exception when invalid_datetime_format or datetime_field_overflow then saved:=null;end;
  if saved is not null and isfinite(saved) and date_trunc('minute',saved at time zone zone)=wall then return saved;end if;
 end if;
 -- Match native wallTime: first fold, or the next valid minute on this same day.
 -- PostgreSQL's default AT TIME ZONE chooses the last fold/retains a gap offset.
 select array_agg(distinct extract(epoch from ((instant at time zone zone)-(instant at time zone 'UTC')))) into offsets
 from (select (wall at time zone 'UTC')+make_interval(hours=>n) instant from generate_series(-36,36,6) n) samples;
 for shift in 0..1439 loop
  wanted:=wall+make_interval(mins=>shift);if wanted::date<>day then return null;end if;
  result:=null;
  foreach offset_seconds in array offsets loop
   candidate:=(wanted-make_interval(secs=>offset_seconds::double precision)) at time zone 'UTC';
   if candidate at time zone zone=wanted and (result is null or candidate<result) then result:=candidate;end if;
  end loop;
  if result is not null then return result;end if;
 end loop;
 return null;
end $$;

create or replace function taskfold_private.normalize_planned_instant()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if new.time_zone is not null and not exists(select 1 from pg_catalog.pg_timezone_names where name=new.time_zone) then raise exception 'Choose a valid time zone';end if;
 if new.due_date is null or new.due_time is null or new.time_zone is null then new.scheduled_at:=null;
 else
  if tg_op='UPDATE' then
   if (new.due_date,new.due_time,new.time_zone) is distinct from (old.due_date,old.due_time,old.time_zone) and new.scheduled_at is not distinct from old.scheduled_at then new.scheduled_at:=null;end if;
  end if;
  new.scheduled_at:=taskfold_private.automation_wall_start(to_jsonb(new),new.time_zone);
 end if;
 return new;
end $$;

-- Only recognize the native absolute/relative versions needed for default/carry
-- decisions. Future or malformed rows stay opaque instead of being discarded.
create function taskfold_private.automation_simple_reminder_kind(s jsonb) returns text
language plpgsql stable security invoker set search_path='' as $$
declare base jsonb; n numeric; stamp timestamptz; sid uuid;
begin
 if jsonb_typeof(s) is distinct from 'object' then return null;end if;
 if s->'version'='4'::jsonb then
  if s->>'presentation' is distinct from 'time-sensitive' or s->'channels' is distinct from '["local"]'::jsonb or s->'schedule_version' is distinct from '1'::jsonb
   or lower(s->>'id')='00000000-0000-4000-8000-000000000001' then return null;end if;
  base:=(s-'presentation'-'schedule_version')||'{"version":1}'::jsonb;
  return taskfold_private.automation_simple_reminder_kind(base);
 end if;
 if s->'version' is distinct from '1'::jsonb or coalesce(s->>'id','')!~*'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
  or (s ? 'enabled' and jsonb_typeof(s->'enabled') is distinct from 'boolean') or jsonb_typeof(s->'channels') is distinct from 'array' then return null;end if;
 if jsonb_array_length(s->'channels')=0 or exists(select 1 from jsonb_array_elements(s->'channels') c where c not in('"local"'::jsonb,'"push"'::jsonb,'"email"'::jsonb)) then return null;end if;
 sid:=(s->>'id')::uuid;
 if s->>'kind'='relative' then
  if s->>'anchor' is distinct from 'planned' or jsonb_typeof(s->'offset_minutes') is distinct from 'number' then return null;end if;
  n:=(s->>'offset_minutes')::numeric;
  if n<>trunc(n) or n not between -10080 and 10080 or (sid='00000000-0000-4000-8000-000000000001' and n<>0) then return null;end if;
  return 'relative';
 elsif s->>'kind'='absolute' then
  if sid='00000000-0000-4000-8000-000000000001' or jsonb_typeof(s->'at') is distinct from 'string'
   or coalesce(s->>'at','')!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.[0-9]+)?(Z|[+-]\d{2}:?\d{2})$'
   or not exists(select 1 from pg_catalog.pg_timezone_names where name=s->>'time_zone') then return null;end if;
  begin stamp:=(s->>'at')::timestamptz;exception when invalid_datetime_format or datetime_field_overflow then return null;end;
  if isfinite(stamp) then return 'absolute';end if;
 end if;
 return null;
end $$;
create function taskfold_private.automation_successor_reminders(rows jsonb) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare kept jsonb;begin
 if jsonb_typeof(rows) is distinct from 'array' or jsonb_array_length(rows)=0 then return '[]';end if;
 select coalesce(jsonb_agg(value order by ord),'[]') into kept from jsonb_array_elements(rows) with ordinality r(value,ord)
 where taskfold_private.automation_simple_reminder_kind(value) is distinct from 'absolute';
 if jsonb_array_length(kept)=0 then return '[{"version":1,"id":"00000000-0000-4000-8000-000000000001","kind":"relative","anchor":"planned","offset_minutes":0,"channels":["local"],"enabled":false}]';end if;
 return kept;
end $$;

create function taskfold_private.automation_automatic_reminder(task jsonb,previous jsonb,minutes int,input_zone text)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare rows jsonb:=case when jsonb_typeof(task->'reminder_specs')='array' then task->'reminder_specs' else '[]'::jsonb end;
 result jsonb:='[]';original_rows jsonb;row jsonb;spec jsonb;placeholder int:=null;index int:=0;sid text;
begin
 original_rows:=rows;
 if minutes is null or minutes not between -1 and 10080 then return task;end if;
 if previous is not null and taskfold_private.automation_wall_start(previous,input_zone) is not null then
  if jsonb_array_length(rows)=0 and taskfold_private.automation_wall_start(task,input_zone) is null then
   rows:='[{"version":1,"id":"00000000-0000-4000-8000-000000000001","kind":"relative","anchor":"planned","offset_minutes":0,"channels":["local"],"enabled":true}]';
  end if;
  for row in select * from jsonb_array_elements(rows) loop
   if taskfold_private.automation_simple_reminder_kind(row)='relative' and lower(row->>'id')='00000000-0000-4000-8000-000000000001'
    and row->'channels'='["local"]'::jsonb and row->'taskfold_default_placeholder'='true'::jsonb then row:=row-'taskfold_default_placeholder';end if;
   result:=result||jsonb_build_array(row);
  end loop;
  if result is distinct from original_rows then return task||jsonb_build_object('reminder_specs',result);end if;
  return task;
 end if;
 if taskfold_private.automation_wall_start(task,input_zone) is null then return task;end if;
 for row in select * from jsonb_array_elements(rows) loop
  if placeholder is null and taskfold_private.automation_simple_reminder_kind(row)='relative' and lower(row->>'id')='00000000-0000-4000-8000-000000000001'
   and coalesce(row->'enabled','true'::jsonb)='true'::jsonb and row->'channels'='["local"]'::jsonb and row->'taskfold_default_placeholder'='true'::jsonb then placeholder:=index;end if;
  index:=index+1;
 end loop;
 if jsonb_array_length(rows)>0 and placeholder is null then return task;end if;
 sid:=case when minutes>0 then '00000000-0000-4000-8000-000000000002' else '00000000-0000-4000-8000-000000000001' end;
 if exists(select 1 from jsonb_array_elements(rows) with ordinality r(value,ord) where (placeholder is null or ord<>placeholder+1) and lower(value->>'id')=sid) then return task;end if;
 spec:=jsonb_build_object('version',1,'id',sid,'kind','relative','anchor','planned','offset_minutes',case when minutes>0 then -minutes else 0 end,'channels',jsonb_build_array('local'),'enabled',minutes<>-1);
 index:=0;
 for row in select * from jsonb_array_elements(rows) loop
  if index=placeholder then spec:=(row-'taskfold_default_placeholder')||spec;else result:=result||jsonb_build_array(row);end if;
  index:=index+1;
 end loop;
 -- Native duplicate semantics for this newly created local relative reminder.
 if spec->'enabled'='false'::jsonb or not exists(select 1 from jsonb_array_elements(result) r(value) where taskfold_private.automation_simple_reminder_kind(r.value)='relative'
  and r.value->'channels' @> '["local"]'::jsonb and coalesce(r.value->'enabled','true'::jsonb)='true'::jsonb and r.value->'offset_minutes'=spec->'offset_minutes') then result:=result||jsonb_build_array(spec);end if;
 if jsonb_array_length(result)>20 then return task;end if;
 return task||jsonb_build_object('reminder_specs',result);
end $$;

create function taskfold_private.automation_successor_children(rows jsonb,root text,path text,delta int,input_zone text,depth int default 0)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare value jsonb;child jsonb;result jsonb:='[]';index int:=0;child_path text;zone text;old_day date;new_day date;
begin
 if depth>=24 then return rows;end if;
 if jsonb_typeof(rows) is distinct from 'array' then return '[]';end if;
 for value in select * from jsonb_array_elements(rows) loop
  if jsonb_typeof(value)='object' then
   child_path:=path||'/'||index::text||':'||coalesce(value->>'id','');child:=value||jsonb_build_object('id',taskfold_private.automation_successor_id(root||child_path,'child'),'completed',false,'completed_at',null,'comments','[]'::jsonb,'deadline_date',null,'notification_sent_at',null,'reminder_specs',taskfold_private.automation_successor_reminders(value->'reminder_specs'));
   zone:=input_zone;
   if coalesce(value->>'due_time','')<>'' and exists(select 1 from pg_catalog.pg_timezone_names where name=value->>'time_zone') then zone:=value->>'time_zone';end if;
   old_day:=taskfold_private.automation_civil_day(left(value->>'due_date',10));
   if old_day is not null and ((old_day::timestamp at time zone zone) at time zone zone)::date=old_day then
    new_day:=taskfold_private.automation_calendar_add_days(old_day,delta,zone);
    child:=child||jsonb_build_object('due_date',to_char(new_day,'YYYY-MM-DD'),'scheduled_at',null);
    if coalesce(child->>'time_zone','')<>'' then child:=child||jsonb_build_object('scheduled_at',taskfold_private.automation_wall_start(child,zone));end if;
   end if;
   if jsonb_typeof(child->'subtasks')='array' then child:=child||jsonb_build_object('subtasks',taskfold_private.automation_successor_children(child->'subtasks',root,child_path,delta,zone,depth+1));end if;
   result:=result||jsonb_build_array(child);
  else result:=result||jsonb_build_array(value);end if;
  index:=index+1;
 end loop;
 return result;
end $$;

create function taskfold_private.automation_successor(task jsonb,account uuid,completed_at timestamptz,input_zone text,action uuid,generation uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare plan jsonb;result jsonb;metadata jsonb;zone text:=input_zone;delta int;old_day date;
begin
 if account is null or action is null or generation is null then raise exception using errcode='22023',message='A recurring successor needs its account and operation identity';end if;
 plan:=taskfold_private.automation_recurrence_plan(task,completed_at,input_zone);if plan is null then return null;end if;
 if coalesce(task->>'due_time','')<>'' and exists(select 1 from pg_catalog.pg_timezone_names where name=task->>'time_zone') then zone:=task->>'time_zone';end if;
 result:=(task-'updated_at')||jsonb_build_object('id',plan->'id','user_id',account,'due_date',plan->'due_date','completed',false,'completed_at',null,'completion_version',0,'task_generation',generation,
 'notification_sent_at',null,'created_at',completed_at,'deadline_date',null,'scheduled_at',null,'comments','[]'::jsonb,'recurrence_parent_id',coalesce(nullif(task->>'recurrence_parent_id',''),task->>'id'),
 'recurrence_pattern',plan->'recurrence_pattern','reminder_specs',taskfold_private.automation_successor_reminders(task->'reminder_specs'));
 if coalesce(task->>'time_zone','')<>'' then result:=result||jsonb_build_object('scheduled_at',taskfold_private.automation_wall_start(result,zone));end if;
 metadata:=case when jsonb_typeof(task->'source_metadata')='object' then task->'source_metadata' else '{}'::jsonb end;
 if task->'source_metadata' is not null and task->'source_metadata'<>'null'::jsonb and jsonb_typeof(task->'source_metadata')<>'object' then metadata:=metadata||jsonb_build_object('taskfold_previous_source_metadata',task->'source_metadata');end if;
 metadata:=metadata||jsonb_build_object('taskfold_recurrence_v1',jsonb_build_object('action_id',action));
 old_day:=taskfold_private.automation_civil_day(left(task->>'due_date',10));
 delta:=case when old_day is null then 0 else taskfold_private.automation_calendar_day_distance(old_day,(plan->>'due_date')::date,zone) end;
 result:=result||jsonb_build_object('source_metadata',metadata,'subtasks',taskfold_private.automation_successor_children(task->'subtasks',plan->>'id','',delta,zone));
 return result;
end $$;

revoke all on function taskfold_private.automation_wall_start(jsonb,text),taskfold_private.normalize_planned_instant(),
 taskfold_private.automation_simple_reminder_kind(jsonb),taskfold_private.automation_successor_reminders(jsonb),
 taskfold_private.automation_automatic_reminder(jsonb,jsonb,int,text),taskfold_private.automation_successor_children(jsonb,text,text,int,text,int),
 taskfold_private.automation_successor(jsonb,uuid,timestamptz,text,uuid,uuid)
 from public,anon,authenticated,service_role;

-- The existing native row trigger is SECURITY INVOKER. Permit only these pure,
-- input-only clock helpers to existing authenticated/service DML roles. They
-- read no task/account data. All successor/default/write helpers remain private.
-- Both roles already have private-schema USAGE in the live schema.
grant execute on function taskfold_private.automation_wall_start(jsonb,text),taskfold_private.automation_civil_day(text) to authenticated,service_role;
