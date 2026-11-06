begin;
set local role service_role;
do $$ declare s jsonb := '{"version":2,"id":"f1751000-0000-4000-8000-000000000002","kind":"recurring","channels":["local"],"enabled":true,"start_day":"2026-10-15","time":"09:00","time_zone":"Europe/Copenhagen","recurrence":{"type":"monthly","interval":1,"daysOfMonth":[15,31],"count":3}}';t jsonb := '{"id":"f1751000-0000-4000-8000-000000000001","user_id":"f1751000-0000-4000-8000-000000000004","title":"Monthly schedule proof","completed":false,"completion_version":7,"task_generation":"f1751000-0000-4000-8000-000000000003","reminder_specs":[{"version":2,"id":"f1751000-0000-4000-8000-000000000002","kind":"recurring","channels":["local"],"enabled":true,"start_day":"2026-10-15","time":"09:00","time_zone":"Europe/Copenhagen","recurrence":{"type":"monthly","interval":1,"daysOfMonth":[15,31],"count":3}}]}';r jsonb;bad jsonb;dates date[];stamp timestamptz;fingerprint text;begin
 if not taskfold_private.reminder_spec_valid(s) then raise exception 'Supported monthly dates rejected';end if;
 select array_agg(value::date order by value) into dates from taskfold_private.reminder_calendar_dates(s,'2026-10-14T00:00:00Z','2026-11-20T00:00:00Z') value;
 if dates is distinct from array[date '2026-10-15',date '2026-10-31',date '2026-11-15'] then raise exception 'Monthly dates/limits drift: %',dates;end if;
 select fire_at,signature into strict stamp,fingerprint from taskfold_private.reminder_events_window(t,'America/New_York','2026-10-30T00:00:00Z','2026-11-02T00:00:00Z');
 if stamp<>'2026-10-31T08:00:00Z'::timestamptz or fingerprint<>'r5:9ed0659acab62189add81d4608ef6c8fc2cae2304c6404d2bcea7fa4db90a4b2' then raise exception 'Client/server clock or signature mismatch: % %',stamp,fingerprint;end if;
 r:=s->'recurrence';
 if taskfold_private.reminder_calendar_next(r,date '2026-10-15',date '2026-10-15')<>date '2026-10-31' then raise exception 'Same month skipped';end if;
 r:='{"type":"monthly","interval":2,"daysOfMonth":[1,15,31]}';
 if taskfold_private.reminder_calendar_next(r,date '2026-01-01',date '2026-03-10')<>date '2026-03-15' or taskfold_private.reminder_calendar_next(r,date '2026-01-01',date '2026-04-10')<>date '2026-05-01' then raise exception 'Monthly interval anchor drift';end if;
 r:='{"type":"monthly","interval":1,"daysOfMonth":[30,31]}';
 if taskfold_private.reminder_calendar_next(r,date '2027-01-31',date '2027-01-31')<>date '2027-02-28' or taskfold_private.reminder_calendar_next(r,date '2027-01-31',date '2027-02-28')<>date '2027-03-30' then raise exception 'Short month clamp drift';end if;
 if taskfold_private.reminder_calendar_next(r,date '2028-01-31',date '2028-01-31')<>date '2028-02-29' then raise exception 'Leap month drift';end if;
 if taskfold_private.reminder_calendar_next(r,date '9999-12-31',date '9999-12-31') is not null then raise exception 'Upper date limit escaped';end if;
 for bad in select x from (values ('[]'::jsonb),('[1,1]'),('[0]'),('[32]'),('[1.5]'),('["15"]'),('[1e100]'),('{}')) v(x) loop
  if taskfold_private.reminder_spec_valid(jsonb_set(s,'{recurrence,daysOfMonth}',bad)) then raise exception 'Invalid dates accepted: %',bad;end if;
 end loop;
 if taskfold_private.reminder_spec_valid(jsonb_set(s,'{recurrence,dayOfMonth}','15')) or taskfold_private.reminder_spec_valid(jsonb_set(s,'{recurrence,type}','"yearly"')) then raise exception 'Ambiguous selectors accepted';end if;
 s:=jsonb_set(s,'{start_day}','"2026-10-16"');if taskfold_private.reminder_spec_valid(s) then raise exception 'Nonoccurrence origin accepted';end if;
end $$;
reset role;
do $$ begin
 if has_function_privilege('anon','taskfold_private.reminder_month_dates(integer,integer,jsonb,integer)','execute') or has_function_privilege('authenticated','taskfold_private.reminder_month_dates(integer,integer,jsonb,integer)','execute') then raise exception 'Client calendar helper exposed';end if;
 if (select prosecdef from pg_proc where oid='taskfold_private.reminder_month_dates(integer,integer,jsonb,integer)'::regprocedure) then raise exception 'Calendar helper bypasses access control';end if;
end $$;
select jsonb_build_object('monthly_date_sets','passed','short_months',true,'intervals',true,'client_server_signature',true,'service_only',true,'rollback_only',true) result;
rollback;
