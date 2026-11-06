-- Candidate only. Independent reminder schedules do not create successor tasks,
-- request permissions, fetch calendars or enable remote notification delivery.
create function taskfold_private.automation_reminder_integer(value jsonb,low numeric,high numeric)
returns boolean language sql immutable security invoker set search_path='' as $$
 select case when jsonb_typeof(value)='number' then (value::text)::numeric=trunc((value::text)::numeric) and (value::text)::numeric between low and high else false end
$$;
create function taskfold_private.automation_calendar_reminder_valid(s jsonb)
returns boolean language plpgsql stable security invoker set search_path='' as $$
declare r jsonb:=s->'recurrence';day date;zone text;clock text;instant timestamptz;
begin
 if jsonb_typeof(s) is distinct from 'object' or not taskfold_private.automation_recurrence_valid(r) then return false;end if;
 day:=taskfold_private.automation_civil_day(s->>'start_day');clock:=s->>'time';zone:=s->>'time_zone';
 if day is null or jsonb_typeof(s->'start_day') is distinct from 'string'
 or jsonb_typeof(s->'time') is distinct from 'string' or clock!~'^([01][0-9]|2[0-3]):[0-5][0-9]$'
 or jsonb_typeof(s->'time_zone') is distinct from 'string' or zone~'^GMT[+-]'
 or not exists(select 1 from pg_catalog.pg_timezone_names where name=zone)
 or coalesce((r->>'fromCompletion')::boolean,false)
 or (nullif(r->'count','null'::jsonb) is not null and not taskfold_private.automation_reminder_integer(r->'count',1,999))
 or (nullif(r->'daysOfWeek','null'::jsonb) is not null and r->>'type'<>'weekly')
 or (nullif(r->'dayOfMonth','null'::jsonb) is not null and r->>'type' not in('monthly','yearly'))
 or (nullif(r->'monthOfYear','null'::jsonb) is not null and r->>'type'<>'yearly')
 or (nullif(r->'weekday','null'::jsonb) is not null and nullif(r->'weekdayOrdinal','null'::jsonb) is null)
 or (r->>'type' in('monthly','yearly') and nullif(r->'dayOfMonth','null'::jsonb) is null and nullif(r->'weekdayOrdinal','null'::jsonb) is null and nullif(r->'daysOfMonth','null'::jsonb) is null)
 or (r->>'type'='yearly' and nullif(r->'monthOfYear','null'::jsonb) is null) then return false;end if;
 -- The authored anchor must itself be the first selected civil occurrence.
 if coalesce(r->>'endDate','')<>'' and day>taskfold_private.automation_civil_day(r->>'endDate') then return false;end if;
 if r->>'type'='weekly' and jsonb_array_length(coalesce(nullif(r->'daysOfWeek','null'::jsonb),'[]'))>0
 and not exists(select 1 from jsonb_array_elements(r->'daysOfWeek') d where d::text::numeric=extract(dow from day)) then return false;end if;
 if r->>'type'='monthly' and not exists(select 1 from taskfold_private.automation_month_dates(extract(year from day)::int,extract(month from day)::int,r,extract(day from day)::int) d where d=day) then return false;end if;
 if r->>'type'='yearly' and (extract(month from day)<>(r->>'monthOfYear')::numeric or not exists(select 1 from taskfold_private.automation_month_dates(extract(year from day)::int,(r->>'monthOfYear')::numeric::int,r,extract(day from day)::int) d where d=day)) then return false;end if;
 -- Refuse a fully skipped civil day or a clock gap with no valid minute remaining
 -- that day. Native readers choose their own earliest valid/fold clock instant.
 instant:=(day::text||' '||clock)::timestamp at time zone zone;
 return (instant at time zone zone)::date=day;
exception when invalid_datetime_format or datetime_field_overflow then return false;
end $$;
create function taskfold_private.automation_holiday_reminder_valid(h jsonb)
returns boolean language plpgsql immutable security invoker set search_path='' as $$
declare value jsonb;previous text;day date;origin jsonb;country text;begin
 if jsonb_typeof(h) is distinct from 'object' or h->'version' is distinct from '1'::jsonb
 or not taskfold_private.automation_reminder_integer(h->'year',1,9999)
 or coalesce(h->>'mode','') not in('skip','next-day') or jsonb_typeof(h->'avoid_weekends') is distinct from 'boolean'
 or jsonb_typeof(h->'source') is distinct from 'string' or coalesce(h->>'source','')!~'[^[:space:]]' or length(h->>'source')>160
 or jsonb_typeof(h->'region') is distinct from 'string' or coalesce(h->>'region','')!~'[^[:space:]]' or length(h->>'region')>160
 or jsonb_typeof(h->'digest') is distinct from 'string' or coalesce(h->>'digest','')!~'^[a-f0-9]{64}$'
 or jsonb_typeof(h->'dates') is distinct from 'array' then return false;end if;
 if jsonb_array_length(h->'dates')>366 then return false;end if;
 for value in select * from jsonb_array_elements(h->'dates') loop
  if jsonb_typeof(value)<>'string' then return false;end if;
  day:=taskfold_private.automation_civil_day(value#>>'{}');
  if day is null or extract(year from day)<>(h->>'year')::numeric or (previous is not null and previous>=value#>>'{}') then return false;end if;
  previous:=value#>>'{}';
 end loop;
 if h ? 'origin' then
  origin:=h->'origin';country:=origin->>'country';
  if jsonb_typeof(origin) is distinct from 'object' or origin->>'provider' is distinct from 'nager-v4'
   or jsonb_typeof(origin->'country') is distinct from 'string' or coalesce(country,'')!~'^[A-Z]{2}$' then return false;end if;
  if origin ? 'subdivision' and (jsonb_typeof(origin->'subdivision') is distinct from 'string' or (origin->>'subdivision')!~'^[A-Z]{2}-[A-Z0-9]{1,3}$' or left(origin->>'subdivision',3)<>country||'-') then return false;end if;
 end if;
 return true;
end $$;
create function taskfold_private.automation_portable_reminder_kind(s jsonb)
returns text language plpgsql stable security invoker set search_path='' as $$
declare payload jsonb;base jsonb;version jsonb;value jsonb;begin
 if jsonb_typeof(s) is distinct from 'object' then return null;end if;
 version:=s->'version';
 if version='4'::jsonb then
  if s->>'presentation' is distinct from 'time-sensitive' or s->'channels' is distinct from '["local"]'::jsonb
   or s->'schedule_version' not in('1'::jsonb,'2'::jsonb,'3'::jsonb,'5'::jsonb) or not(s ? 'schedule_version')
   or lower(s->>'id')='00000000-0000-4000-8000-000000000001' then return null;end if;
  base:=(s-'presentation'-'schedule_version')||jsonb_build_object('version',s->'schedule_version');
  return taskfold_private.automation_portable_reminder_kind(base);
 end if;
 if version='1'::jsonb then return taskfold_private.automation_simple_reminder_kind(s);end if;
 if version not in('2'::jsonb,'3'::jsonb,'5'::jsonb) or version is null
 or coalesce(s->>'id','')!~*'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
 or lower(s->>'id')='00000000-0000-4000-8000-000000000001' or s->'channels' is distinct from '["local"]'::jsonb
 or (s ? 'enabled' and jsonb_typeof(s->'enabled') is distinct from 'boolean') then return null;end if;
 if version in('2'::jsonb,'5'::jsonb) then
  if s->>'kind' is distinct from 'recurring' or not taskfold_private.automation_calendar_reminder_valid(s) then return null;end if;
  if version='5'::jsonb and not taskfold_private.automation_holiday_reminder_valid(s->'holiday_policy') then return null;end if;
  return 'recurring';
 end if;
 if s->>'kind' is distinct from 'interval' or jsonb_typeof(s->'interval_schedule') is distinct from 'object' then return null;end if;
 payload:=s->'interval_schedule';
 if not taskfold_private.automation_reminder_integer(payload->'start_ms',-62135596800000,253402300799999)
 or not taskfold_private.automation_reminder_integer(payload->'every_minutes',5,10080) then return null;end if;
 if nullif(payload->'count','null'::jsonb) is not null and not taskfold_private.automation_reminder_integer(payload->'count',1,999) then return null;end if;
 value:=nullif(payload->'until_ms','null'::jsonb);
 if value is not null and (not taskfold_private.automation_reminder_integer(value,-62135596800000,253402300799999) or value::text::numeric<(payload->>'start_ms')::numeric) then return null;end if;
 return 'interval';
end $$;
revoke all on function taskfold_private.automation_reminder_integer(jsonb,numeric,numeric),taskfold_private.automation_calendar_reminder_valid(jsonb),
 taskfold_private.automation_holiday_reminder_valid(jsonb),taskfold_private.automation_portable_reminder_kind(jsonb) from public,anon,authenticated,service_role;

-- Supported schedules may carry fields from newer native readers. Editing known
-- settings must retain those extension values, including nested rule/policy data.
create function taskfold_private.automation_reminder_extensions(s jsonb)
returns jsonb language sql immutable security invoker set search_path='' as $$
 select jsonb_build_object(
 'row',s-array['version','id','kind','enabled','channels','anchor','offset_minutes','at','time_zone','start_day','time','recurrence','interval_schedule','holiday_policy','schedule_version','presentation','taskfold_default_placeholder'],
 'recurrence',case when jsonb_typeof(s->'recurrence')='object' then (s->'recurrence')-array['type','interval','daysOfWeek','dayOfMonth','daysOfMonth','monthOfYear','weekday','weekdayOrdinal','count','endDate','fromCompletion'] else '{}'::jsonb end,
 'interval',case when jsonb_typeof(s->'interval_schedule')='object' then (s->'interval_schedule')-array['start_ms','every_minutes','count','until_ms'] else '{}'::jsonb end,
 'holiday',case when jsonb_typeof(s->'holiday_policy')='object' then (s->'holiday_policy')-array['version','year','dates','source','region','digest','mode','avoid_weekends','origin'] else '{}'::jsonb end,
 'origin',case when jsonb_typeof(s->'holiday_policy'->'origin')='object' then (s->'holiday_policy'->'origin')-array['provider','country','subdivision'] else '{}'::jsonb end)
$$;
create function taskfold_private.automation_reminder_extensions_preserved(previous jsonb,proposed jsonb)
returns boolean language sql immutable security invoker set search_path='' as $$
 select not exists(select 1 from jsonb_each(taskfold_private.automation_reminder_extensions(previous)) part,
  lateral jsonb_each(part.value) extension
  where extension.value is distinct from taskfold_private.automation_reminder_extensions(proposed)->part.key->extension.key)
$$;
revoke all on function taskfold_private.automation_reminder_extensions(jsonb),taskfold_private.automation_reminder_extensions_preserved(jsonb,jsonb) from public,anon,authenticated,service_role;

-- Preserve the existing field, checklist, identity and unknown-row guards.
create or replace function taskfold_private.automation_validate_fields(f jsonb,previous jsonb)
returns void language plpgsql stable security invoker set search_path='' as $$
declare k text;v jsonb;s jsonb;old jsonb;previous_specs jsonb:=case when jsonb_typeof(previous->'reminder_specs')='array' then previous->'reminder_specs' else '[]'::jsonb end;ids uuid[]:=array[]::uuid[];n numeric;
 allowed constant text[]:=array['title','description','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','reminder_specs','recurrence_pattern','is_recurring','recurrence_end_date','assigned_to','deadline_date','duration_minutes','time_zone','scheduled_at'];
begin
 if jsonb_typeof(f) is distinct from 'object' or exists(select 1 from jsonb_object_keys(f) x where not x=any(allowed)) then raise exception using errcode='22023',message='Use supported task detail fields';end if;
 for k,v in select * from jsonb_each(f) loop
  if k='title' then
   if jsonb_typeof(v)<>'string' or length(regexp_replace(v#>>'{}','[[:space:]]','','g'))=0 or octet_length(v#>>'{}')>8192 then raise exception using errcode='22023',message='Give the task a supported title';end if;
  elsif k='description' then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or octet_length(v#>>'{}')>512000) then raise exception using errcode='22023',message='Use a supported task description';end if;
  elsif k in('priority','duration_minutes') then
   if k='duration_minutes' and v='null'::jsonb then continue;end if;
   if jsonb_typeof(v)<>'number' then raise exception using errcode='22023',message='Use a whole-number priority or estimate';end if;
   n:=v::text::numeric;
   if n<>trunc(n) or (k='priority' and n not between 1 and 4) or (k='duration_minutes' and n not between 1 and 10080) then raise exception using errcode='22023',message='Use a supported priority or estimate';end if;
  elsif k in('due_date','deadline_date','recurrence_end_date') then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or taskfold_private.automation_civil_day(v#>>'{}') is null) then raise exception using errcode='22023',message='Use an ISO calendar date';end if;
  elsif k='due_time' then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or (v#>>'{}')!~'^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9](\.[0-9]+)?)?$') then raise exception using errcode='22023',message='Use a valid task clock';end if;
  elsif k in('project_id','section_id','assigned_to') then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or (v#>>'{}')!~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') then raise exception using errcode='22023',message='Use a valid task reference';end if;
  elsif k='time_zone' then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or not exists(select 1 from pg_catalog.pg_timezone_names where name=v#>>'{}')) then raise exception using errcode='22023',message='Choose a named time zone';end if;
  elsif k='scheduled_at' then
   if v<>'null'::jsonb then
    if jsonb_typeof(v)<>'string' or (v#>>'{}')!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.[0-9]+)?(Z|[+-]\d{2}:?\d{2})$' or not isfinite((v#>>'{}')::timestamptz) then raise exception using errcode='22023',message='Use an explicit scheduled instant';end if;
   end if;
  elsif k in('labels','reminders') then
   if jsonb_typeof(v)<>'array' or jsonb_array_length(v)>256 then raise exception using errcode='22023',message='Use a bounded text list';end if;
   if exists(select 1 from jsonb_array_elements(v) e where jsonb_typeof(e)<>'string' or octet_length(e#>>'{}')>1024 or length(e#>>'{}')=0) then raise exception using errcode='22023',message='Use nonempty text list values';end if;
  elsif k='is_recurring' and jsonb_typeof(v)<>'boolean' then raise exception using errcode='22023',message='Use a valid repeat state';
  elsif k='recurrence_pattern' and v<>'null'::jsonb and jsonb_typeof(v)<>'object' then raise exception using errcode='22023',message='Use a repeat rule object';
  elsif k='reminder_specs' then
   if jsonb_typeof(v)<>'array' or jsonb_array_length(v)>20 then raise exception using errcode='22023',message='Use up to twenty reminder choices';end if;
   for s in select * from jsonb_array_elements(v) loop
    if jsonb_typeof(s)<>'object' or coalesce(s->>'id','')!~*'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then raise exception using errcode='22023',message='Use a valid reminder identity';end if;
    if (s->>'id')::uuid=any(ids) then raise exception using errcode='22023',message='Use unique reminder identities';end if;ids:=array_append(ids,(s->>'id')::uuid);
    select e into old from jsonb_array_elements(previous_specs) e where lower(e->>'id')=lower(s->>'id') limit 1;
    if old is not null and taskfold_private.automation_portable_reminder_kind(old) is not null
     and not taskfold_private.automation_reminder_extensions_preserved(old,s) then
     raise exception using errcode='22023',message='Preserve reminder extension fields from the reviewed baseline';
    end if;
    if taskfold_private.automation_portable_reminder_kind(s) is null then
     if not exists(select 1 from jsonb_array_elements(previous_specs) e where e=s) then raise exception using errcode='22023',message='Use a supported portable reminder; review private locations in Taskfold';end if;
    end if;
   end loop;
   for old in select * from jsonb_array_elements(previous_specs) loop
    if taskfold_private.automation_portable_reminder_kind(old) is null and not exists(select 1 from jsonb_array_elements(v) e where e=old) then raise exception using errcode='22023',message='Preserve unknown and private reminder choices';end if;
   end loop;
  end if;
 end loop;
end $$;
