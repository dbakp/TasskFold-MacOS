-- Bounded synthetic comparisons and actual-role owner/device queue fixtures.
-- No provider requests or real task changes; all state rolls back.
begin; set local statement_timeout='55s';
create temporary table taskfold_cohort_metrics(name text,seconds numeric,result jsonb) on commit drop;
do $$ begin execute format('grant usage on schema %I to service_role',(select nspname from pg_namespace where oid=pg_my_temp_schema())); end $$;
grant select,insert on pg_temp.taskfold_cohort_metrics to service_role;
create function pg_temp.reminder_calendar_dates_reference(s jsonb,_after timestamptz,_until timestamptz)
returns setof timestamptz language plpgsql stable security invoker set search_path='' as $$
declare r jsonb:=s->'recurrence'; origin date; day date; threshold date; at timestamptz; emitted int:=0; consumed int:=0; count_limit int; zone text:=s->>'time_zone'; clock time;
begin
 if _after is null or _until is null or not isfinite(_after) or not isfinite(_until) or _until<=_after or s->'version'<>'2'::jsonb then return; end if;
 origin:=(s->>'start_day')::date; clock:=(s->>'time')::time; count_limit:=nullif(r->'count','null'::jsonb)::text::numeric::int; day:=origin;
 if count_limit is null then
  at:=taskfold_private.reminder_calendar_wall_time(day+clock,zone);
  if at>_after and at<=_until then return next at; emitted:=1; end if;
  threshold:=greatest(origin,timezone(zone,_after)::date-1);
  day:=taskfold_private.reminder_calendar_next(r,origin,threshold);
 end if;
 while day is not null and emitted<60 loop
  -- A past exact wall-time round trip proves this civil day consumed one count.
  -- The default second fold is safe only when it is also past. Gaps/skipped days
  -- and any possible future first fold still use the exact native resolver.
  at:=(day+clock) at time zone zone;
  if count_limit is not null and at<=_after and timezone(zone,at)=day+clock then
   consumed:=consumed+1;
  else
   at:=taskfold_private.reminder_calendar_wall_time(day+clock,zone);
   if at>_until then exit; end if;
   if at is not null then
    consumed:=consumed+1;
    if at>_after then return next at; emitted:=emitted+1; end if;
   end if;
  end if;
  if count_limit is not null and consumed>=count_limit then exit; end if;
  day:=taskfold_private.reminder_calendar_next(r,origin,day);
 end loop;
end $$;
create function pg_temp.reminder_spec_reference(s jsonb)
returns boolean language plpgsql stable security invoker set search_path='' as $$
declare r jsonb; k text; value jsonb; field text; bounds int[]; number numeric; origin date; candidate date; start_month date; days int[]; sid uuid;
begin
 if jsonb_typeof(s)<>'object' or s->'version' is null or s->'version' not in ('1'::jsonb,'2'::jsonb)
  or coalesce(s->>'id','') !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
  or (s ? 'enabled' and jsonb_typeof(s->'enabled')<>'boolean') then return false; end if;
 if jsonb_typeof(s->'channels') is distinct from 'array' then return false; end if;
 if jsonb_array_length(s->'channels')=0 or exists(select 1 from jsonb_array_elements(s->'channels') c where jsonb_typeof(c)<>'string' or c#>>'{}' not in ('local','push','email')) then return false; end if;
 sid:=(s->>'id')::uuid; k:=s->>'kind';
 if k='relative' and s->'version'='1'::jsonb then
  if s->>'anchor' is distinct from 'planned' or jsonb_typeof(s->'offset_minutes') is distinct from 'number' then return false; end if;
  number:=(s->>'offset_minutes')::numeric;
  return number=trunc(number) and number between -10080 and 10080 and (sid<>'00000000-0000-4000-8000-000000000001' or number=0);
 elsif k='absolute' and s->'version'='1'::jsonb then
  if sid='00000000-0000-4000-8000-000000000001' or jsonb_typeof(s->'at') is distinct from 'string'
   or coalesce(s->>'at','') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$'
   or not taskfold_private.reminder_named_time_zone_valid(s->>'time_zone') then return false; end if;
  return isfinite((s->>'at')::timestamptz);
 elsif k is distinct from 'recurring' or s->'version'<>'2'::jsonb or s->'channels'<>'["local"]'::jsonb or sid='00000000-0000-4000-8000-000000000001' then return false; end if;
 if jsonb_typeof(s->'start_day') is distinct from 'string' or coalesce(s->>'start_day','') !~ '^\d{4}-\d{2}-\d{2}$'
  or jsonb_typeof(s->'time') is distinct from 'string' or coalesce(s->>'time','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
  or not taskfold_private.reminder_named_time_zone_valid(s->>'time_zone') or jsonb_typeof(s->'recurrence') is distinct from 'object' then return false; end if;
 origin:=(s->>'start_day')::date; if extract(year from origin) not between 1 and 9999 or to_char(origin,'YYYY-MM-DD')<>s->>'start_day' then return false; end if;
 r:=s->'recurrence'; k:=r->>'type'; if k is null or k not in ('daily','custom','weekly','monthly','yearly') then return false; end if;
 for field,bounds in select * from (values ('interval',array[1,10000]),('dayOfMonth',array[1,31]),('monthOfYear',array[1,12]),('weekday',array[0,6]),('weekdayOrdinal',array[-1,5]),('count',array[1,999])) f(name,limits) loop
  value:=nullif(r->field,'null'::jsonb);
  if value is not null then
   if jsonb_typeof(value)<>'number' then return false; end if;
   number:=value::text::numeric; if number<>trunc(number) or number not between bounds[1] and bounds[2] or (field='weekdayOrdinal' and number=0) then return false; end if;
  end if;
 end loop;
 if nullif(r->'fromCompletion','null'::jsonb) is not null and r->'fromCompletion'<>'false'::jsonb then return false; end if;
 if nullif(r->'endDate','null'::jsonb) is not null then
  if jsonb_typeof(r->'endDate')<>'string' then return false; end if;
  if r->>'endDate'<>'' and ((r->>'endDate') !~ '^\d{4}-\d{2}-\d{2}$' or (r->>'endDate')::date<origin) then return false; end if;
 end if;
 if nullif(r->'daysOfWeek','null'::jsonb) is not null then
  if k<>'weekly' or jsonb_typeof(r->'daysOfWeek')<>'array' then return false; end if;
  if jsonb_array_length(r->'daysOfWeek')>7 then return false; end if;
  for value in select * from jsonb_array_elements(r->'daysOfWeek') loop
   if jsonb_typeof(value)<>'number' then return false; end if; number:=value::text::numeric;
   if number<>trunc(number) or number not between 0 and 6 then return false; end if;
  end loop;
 end if;
 if nullif(r->'dayOfMonth','null'::jsonb) is not null and k not in ('monthly','yearly') then return false; end if;
 if nullif(r->'monthOfYear','null'::jsonb) is not null and k<>'yearly' then return false; end if;
 if nullif(r->'weekdayOrdinal','null'::jsonb) is not null and (k<>'monthly' or nullif(r->'weekday','null'::jsonb) is null) then return false; end if;
 if nullif(r->'weekday','null'::jsonb) is not null and nullif(r->'weekdayOrdinal','null'::jsonb) is null then return false; end if;
 if k in ('monthly','yearly') and nullif(r->'dayOfMonth','null'::jsonb) is null and nullif(r->'weekdayOrdinal','null'::jsonb) is null then return false; end if;
 if k='yearly' and nullif(r->'monthOfYear','null'::jsonb) is null then return false; end if;
 if k='weekly' and coalesce(jsonb_array_length(nullif(r->'daysOfWeek','null'::jsonb)),0)>0
  and not exists(select 1 from jsonb_array_elements(r->'daysOfWeek') d where d::text::numeric::int=extract(dow from origin)::int) then return false; end if;
 if k in ('monthly','yearly') then
  candidate:=taskfold_private.reminder_month_day(extract(year from origin)::int,case when k='yearly' then (r->>'monthOfYear')::numeric::int else extract(month from origin)::int end,r,extract(day from origin)::int);
  if candidate is distinct from origin then return false; end if;
 end if;
 return taskfold_private.reminder_calendar_wall_time(origin+(s->>'time')::time,s->>'time_zone') is not null;
exception when others then return false;
end $$;
grant execute on function pg_temp.reminder_calendar_dates_reference(jsonb,timestamptz,timestamptz),pg_temp.reminder_spec_reference(jsonb) to service_role;
-- Compare the optimized iterator with the pre-optimization exact iterator.
-- No client or provider delivery occurs; the caller wraps this in ROLLBACK.
set local role service_role;
do $$ declare s jsonb; r jsonb; origin text; zone text; clock text; expected timestamptz[]; actual timestamptz[]; boundary timestamptz; tested int:=0; begin
 for r in select v from (values
  ('{"type":"daily","count":999}'::jsonb),('{"type":"custom","interval":2,"count":999}'::jsonb),
  ('{"type":"weekly","interval":3,"count":999}'::jsonb),('{"type":"daily","count":3}'::jsonb),
  ('{"type":"weekly","daysOfWeek":[4,5,6],"count":999}'::jsonb),
  ('{"type":"monthly","dayOfMonth":29,"count":999}'::jsonb),
  ('{"type":"yearly","monthOfYear":12,"dayOfMonth":29,"count":999}'::jsonb),
  ('{"type":"daily","interval":2,"count":999,"endDate":"2012-01-05"}'::jsonb)
 ) pattern(v) loop
  foreach zone in array array['Etc/UTC','Europe/Copenhagen','America/New_York','Australia/Lord_Howe','Pacific/Apia'] loop
   foreach clock in array array['00:00','02:15','02:30','09:00'] loop
    s:=jsonb_build_object('version',2,'id','f0711000-0000-4000-8000-000000000011','kind','recurring','enabled',true,'channels',jsonb_build_array('local'),'start_day','2011-12-29','time',clock,'time_zone',zone,'recurrence',r);
    if not taskfold_private.reminder_spec_valid(s) then raise exception 'Differential fixture invalid: %',s; end if;
    foreach boundary in array array['2011-12-29T00:00:00Z'::timestamptz,'2012-01-01T00:00:00Z'::timestamptz,'2012-04-01T00:00:00Z'::timestamptz,'2014-10-26T01:00:00Z'::timestamptz,'2026-10-25T01:00:00Z'::timestamptz] loop
     select array_agg(v order by v) into expected from pg_temp.reminder_calendar_dates_reference(s,boundary,boundary+interval '8 days') v;
     select array_agg(v order by v) into actual from taskfold_private.reminder_calendar_dates_validated(s,boundary,boundary+interval '8 days') v;
     if actual is distinct from expected then raise exception 'Calendar optimization diverged: % / % / % vs %',s,boundary,actual,expected; end if;
     tested:=tested+1;
    end loop;
   end loop;
  end loop;
 end loop;
 -- Upper-year and long intervals stay bounded; no generated date exceeds 9999.
 foreach r in array array['{"type":"daily","interval":10000,"count":999}'::jsonb,'{"type":"weekly","interval":10000,"count":999}'::jsonb,'{"type":"daily","count":999,"endDate":"9999-12-31"}'::jsonb] loop
  s:=jsonb_build_object('version',2,'id','f0711000-0000-4000-8000-000000000011','kind','recurring','enabled',true,'channels',jsonb_build_array('local'),'start_day','9999-12-29','time','09:00','time_zone','Etc/UTC','recurrence',r);
  select array_agg(v order by v) into expected from pg_temp.reminder_calendar_dates_reference(s,'9999-12-29T00:00Z','9999-12-31T23:59Z') v;
  select array_agg(v order by v) into actual from taskfold_private.reminder_calendar_dates_validated(s,'9999-12-29T00:00Z','9999-12-31T23:59Z') v;
  if actual is distinct from expected then raise exception 'Upper Gregorian boundary diverged'; end if;
  tested:=tested+1;
 end loop;
 if tested<>803 then raise exception 'Differential coverage incomplete: %',tested; end if;
end $$;
reset role;
set local role service_role;
do $$ declare s jsonb; z text; day text; clock text; boundary timestamptz; r jsonb; expected timestamptz[]; actual timestamptz[]; tested int:=0; begin
 foreach z in array array['Africa/Monrovia','Asia/Kathmandu','Pacific/Kwajalein','Pacific/Apia','Europe/Amsterdam'] loop
  foreach day in array array['1900-01-01','1970-01-01','1993-08-20'] loop
   foreach clock in array array['00:00','00:30','02:30','23:45'] loop
    foreach r in array array['{"type":"daily","count":3}'::jsonb,'{"type":"custom","interval":2,"count":999}'::jsonb] loop
     s:=jsonb_build_object('version',2,'id','f0711000-0000-4000-8000-000000000011','kind','recurring','channels',jsonb_build_array('local'),'start_day',day,'time',clock,'time_zone',z,'recurrence',r);
     if taskfold_private.reminder_spec_valid(s) is distinct from pg_temp.reminder_spec_reference(s) then raise exception 'Origin validation diverged: %',s; end if;
     if not taskfold_private.reminder_spec_valid(s) then continue; end if;
     foreach boundary in array array['1900-01-03T00:00Z'::timestamptz,'1972-01-07T00:30Z'::timestamptz,'1993-08-21T10:00Z'::timestamptz,'2026-10-25T01:00Z'::timestamptz] loop
      select array_agg(v order by v) into expected from pg_temp.reminder_calendar_dates_reference(s,boundary,boundary+interval '8 days') v;
      select array_agg(v order by v) into actual from taskfold_private.reminder_calendar_dates_validated(s,boundary,boundary+interval '8 days') v;
      if actual is distinct from expected then raise exception 'Historical-zone differential drift: % / % / % vs %',s,boundary,actual,expected; end if;
      tested:=tested+1;
     end loop;
    end loop;
   end loop;
  end loop;
 end loop;
 if tested<>480 then raise exception 'Historical comparison coverage incomplete: %',tested; end if;
end $$;
reset role;
-- Two authenticated fixture devices; whole-account projection, retries and private ACLs.
-- No provider requests. Transaction is rolled back by this test's caller.
do $$ begin
 if exists(select 1 from auth.users where id::text like 'f0711000-%') or exists(select 1 from public.tasks where id::text like 'f0712000-%') then raise exception 'Cohort namespace already in use'; end if;
 if has_table_privilege('anon','taskfold_private.reminder_time_zones','SELECT') or has_table_privilege('authenticated','taskfold_private.reminder_time_zones','SELECT') or not has_table_privilege('service_role','taskfold_private.reminder_time_zones','SELECT') then raise exception 'Timezone table boundary incorrect'; end if;
 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='taskfold_private' and p.proname in ('refresh_reminder_time_zones','reminder_named_time_zone_valid') and (p.prosecdef or has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE') or not has_function_privilege('service_role',p.oid,'EXECUTE'))) then raise exception 'Timezone helper boundary incorrect'; end if;
end $$;
set local role service_role;
do $$ declare n int; begin
 if taskfold_private.refresh_reminder_time_zones()<>0 then raise exception 'Fresh catalog rescanned'; end if;
 insert into taskfold_private.reminder_time_zones(name,refreshed_at) values('Taskfold/ObsoleteFixture',now()-interval '2 hours');
 n:=taskfold_private.refresh_reminder_time_zones(true);
 if n<>(select count(*) from pg_catalog.pg_timezone_names) or exists(select 1 from taskfold_private.reminder_time_zones where name='Taskfold/ObsoleteFixture') then raise exception 'Forced cache refresh lost exact names'; end if;
 update taskfold_private.reminder_time_zones set refreshed_at=clock_timestamp()-interval '2 hours';
 if taskfold_private.refresh_reminder_time_zones()<>n or taskfold_private.refresh_reminder_time_zones()<>0 then raise exception 'Hourly refresh did not renew exactly once'; end if;
 if exists((select name from pg_catalog.pg_timezone_names except select name from taskfold_private.reminder_time_zones) union all (select name from taskfold_private.reminder_time_zones except select name from pg_catalog.pg_timezone_names)) then raise exception 'Cached names differ from native catalog'; end if;
 if taskfold_private.reminder_named_time_zone_valid(null) or taskfold_private.reminder_named_time_zone_valid('GMT+0200') or taskfold_private.reminder_named_time_zone_valid('europe/copenhagen') or not taskfold_private.reminder_named_time_zone_valid('Europe/Copenhagen') then raise exception 'Named-zone contract changed'; end if;
 begin perform taskfold_private.refresh_reminder_time_zones(null); raise exception 'Null refresh accepted'; exception when others then if sqlerrm<>'Invalid timezone refresh choice.' then raise; end if; end;
end $$;
reset role;
insert into auth.users(id,email) values('f0711000-0000-4000-8000-000000000001','taskfold-cohort@example.invalid'),('f0711000-0000-4000-8000-000000000009','taskfold-cohort-other@example.invalid');
insert into auth.sessions(id,user_id) values('f0711000-0000-4000-8000-000000000002','f0711000-0000-4000-8000-000000000001');
set local request.jwt.claim.sub='f0711000-0000-4000-8000-000000000001';
set local request.jwt.claims='{"sub":"f0711000-0000-4000-8000-000000000001","session_id":"f0711000-0000-4000-8000-000000000002"}';
set local role authenticated;
do $$ declare binding jsonb; device uuid; i int; begin
 for i in 3..5 loop
  device:=('f0711000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid;
  binding:=jsonb_build_object('platform',case when i=4 then 'macos' else 'ios' end,'bundle',case when i=4 then 'com.dbakp.taskfold.mac' else 'com.dbakp.taskfold' end,'environment','development','token',repeat(i::text,64),'time_zone',case when i=4 then 'Europe/Copenhagen' else 'America/New_York' end,'permission','authorized','enabled',false);
  perform public.taskfold_register_reminder_device(device,repeat(i::text,64),1,binding);
  if i<>5 then perform public.taskfold_register_reminder_device(device,repeat(i::text,64),2,binding||'{"enabled":true}'); end if;
 end loop;
 begin perform taskfold_private.refresh_reminder_time_zones(true); raise exception 'Client refreshed private catalog'; exception when insufficient_privilege then null; end;
 begin perform taskfold_private.reminder_named_time_zone_valid('UTC'); raise exception 'Client read private catalog helper'; exception when insufficient_privilege then null; end;
 begin perform 1 from taskfold_private.reminder_time_zones; raise exception 'Client read private catalog table'; exception when insufficient_privilege then null; end;
 -- 100 tasks with 20 historical count-limited settings each.
 insert into public.tasks(id,user_id,title,reminder_specs)
 select ('f0712000-0000-4000-8000-'||lpad(tasks.task_index::text,12,'0'))::uuid,auth.uid(),'Expired calendar cohort',
 (select jsonb_agg(jsonb_build_object('version',2,'id',md5(settings.n::text||gen_random_uuid()::text)::uuid,'kind','recurring','enabled',true,'channels',jsonb_build_array('local'),'start_day','2020-01-01','time','02:30','time_zone',(array['Etc/UTC','Europe/Copenhagen','America/New_York','Australia/Lord_Howe','Pacific/Apia'])[1+tasks.task_index%5],'recurrence',jsonb_build_object('type','daily','count',999))) from generate_series(1,20) settings(n))
 from generate_series(1,100) tasks(task_index);
 -- 50 tasks with 20 invalid names each remain inert and inexpensive.
 insert into public.tasks(id,user_id,title,reminder_specs)
 select ('f0712000-0000-4000-8000-'||lpad(tasks.task_index::text,12,'0'))::uuid,auth.uid(),'Invalid calendar cohort',
 (select jsonb_agg(jsonb_build_object('version',2,'id',md5(settings.n::text||gen_random_uuid()::text)::uuid,'kind','recurring','enabled',true,'channels',jsonb_build_array('local'),'start_day','2020-01-01','time','09:00','time_zone','GMT+0200','recurrence',jsonb_build_object('type','daily','count',999))) from generate_series(1,20) settings(n))
 from generate_series(101,150) tasks(task_index);
 -- 10 active calendars each emit exactly three future occurrences.
 insert into public.tasks(id,user_id,title,reminder_specs)
 select ('f0712000-0000-4000-8000-'||lpad(tasks.task_index::text,12,'0'))::uuid,auth.uid(),'Active calendar cohort',jsonb_build_array(jsonb_build_object('version',2,'id',gen_random_uuid(),'kind','recurring','enabled',true,'channels',jsonb_build_array('local'),'start_day',to_char(timezone('Europe/Copenhagen',now())::date+1,'YYYY-MM-DD'),'time','02:30','time_zone','Europe/Copenhagen','recurrence',jsonb_build_object('type','daily','count',3)))
 from generate_series(151,160) tasks(task_index);
end $$;
reset role;
-- Foreign owner is inserted by the administrative test role, never the client.
insert into public.tasks(id,user_id,title,reminder_specs) select 'f0712000-0000-4000-8000-000000000161','f0711000-0000-4000-8000-000000000009','Foreign calendar',reminder_specs from public.tasks where id='f0712000-0000-4000-8000-000000000151';
set local role service_role;
do $$ declare device uuid; i int; pass int; result jsonb; started timestamptz; elapsed numeric; begin
 for pass in 1..2 loop
  for i in 3..4 loop
   device:=('f0711000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid;
   started:=clock_timestamp(); result:=public.taskfold_reconcile_reminder_jobs(device); elapsed:=extract(epoch from clock_timestamp()-started);
   insert into pg_temp.taskfold_cohort_metrics values('device-'||i||'-pass-'||pass,elapsed,result);
   if elapsed>=4 then raise exception 'Whole-device projection exceeded 4s budget: %',elapsed; end if;
   if (result->>'queued')::int<>(case when pass=1 then 30 else 0 end) then raise exception 'Cohort queue mismatch: %',result; end if;
  end loop;
 end loop;
 if public.taskfold_reconcile_reminder_jobs('f0711000-0000-4000-8000-000000000005')->>'queued'<>'0' then raise exception 'Inactive device got jobs'; end if;
 if (select count(*) from taskfold_private.reminder_jobs where device_id in ('f0711000-0000-4000-8000-000000000003','f0711000-0000-4000-8000-000000000004'))<>60 then raise exception 'Cohort lost or duplicated jobs'; end if;
 if (select count(distinct signature) from taskfold_private.reminder_jobs where device_id in ('f0711000-0000-4000-8000-000000000003','f0711000-0000-4000-8000-000000000004'))<>30 then raise exception 'Device-zone changed calendar signatures'; end if;
 if exists(select 1 from taskfold_private.reminder_jobs where task_id='f0712000-0000-4000-8000-000000000161') then raise exception 'Foreign task leaked into cohort'; end if;
end $$;
reset role;



select jsonb_agg(to_jsonb(m) order by name) as metrics from pg_temp.taskfold_cohort_metrics m;
rollback;
