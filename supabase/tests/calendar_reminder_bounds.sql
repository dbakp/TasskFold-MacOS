-- Pure calendar guard/count/budget regression; no Auth/device/job/provider mutations.
begin;
set local role service_role;
do $$ declare
 s jsonb:='{ "version":2,"id":"f0701000-0000-4000-8000-000000000011","kind":"recurring","enabled":true,"channels":["local"],"start_day":"2026-10-24","time":"02:30","time_zone":"Europe/Copenhagen","recurrence":{"type":"daily","count":3}}';
 times timestamptz[]; task jsonb; measured timestamptz;
begin
 -- After the first fold but before the default second fold, consumed totals must
 -- neither re-emit the second fold nor accidentally reset to three future events.
 select array_agg(v order by v) into times from taskfold_private.reminder_calendar_dates(s,'2026-10-25T01:00:00Z','2026-10-28T00:00:00Z') v;
 if times is distinct from array['2026-10-26T01:30:00Z'::timestamptz] then raise exception 'Finite count re-emitted second fold: %',times; end if;
 task:=jsonb_build_object('id','f0701000-0000-4000-8000-000000000010','reminder_specs',jsonb_build_array(s));
 if exists(select 1 from taskfold_private.reminder_events_window(task,'UTC','2026-10-24T00:00:00Z','2026-11-02T00:00:00Z')) then raise exception 'Oversized projector window accepted'; end if;
 if exists(select 1 from taskfold_private.reminder_events_window(task,'UTC','infinity','infinity')) or exists(select 1 from taskfold_private.reminder_events_window(task,'UTC','2026-10-25','2026-10-24')) then raise exception 'Invalid projector window accepted'; end if;
 if exists(select 1 from taskfold_private.reminder_calendar_dates(s,'-infinity','infinity')) then raise exception 'Unbounded calendar input accepted'; end if;
 if exists(select 1 from taskfold_private.reminder_calendar_dates(s,null,'2026-10-28')) or exists(select 1 from taskfold_private.reminder_calendar_dates(s,'2026-10-24',null)) then raise exception 'NULL calendar boundary accepted'; end if;
 if exists(select 1 from taskfold_private.reminder_calendar_dates_validated(s,null,'2026-10-28')) or exists(select 1 from taskfold_private.reminder_calendar_dates_validated(s,'2026-10-24',null)) then raise exception 'NULL internal calendar boundary accepted'; end if;
 if exists(select 1 from taskfold_private.reminder_events_window(task,'UTC',null,'2026-10-28')) or exists(select 1 from taskfold_private.reminder_events_window(task,'UTC','2026-10-24',null)) then raise exception 'NULL projector boundary accepted'; end if;
 -- Maximum raw settings, each with 999 historical occurrences. A one-task
 -- projection must fit within the worker's five-second RPC budget with margin.
 task:=task||jsonb_build_object('task_generation','f0701000-0000-4000-8000-000000000012','completion_version',2,'reminder_specs',(select jsonb_agg(jsonb_build_object('version',2,'id','f0701000-0000-4000-8000-'||lpad(i::text,12,'0'),'kind','recurring','enabled',true,'channels',jsonb_build_array('local'),'start_day','2020-01-01','time','09:00','time_zone','Etc/UTC','recurrence',jsonb_build_object('type','daily','count',999))) from generate_series(1,20) i));
 measured:=clock_timestamp();
 if exists(select 1 from taskfold_private.reminder_events_window(task,'America/New_York','2026-10-24T00:00:00Z','2026-10-28T00:00:00Z')) then raise exception 'Historical count restarted'; end if;
 if clock_timestamp()-measured>interval '4 seconds' then raise exception 'Maximum-setting calendar projection exceeded RPC budget'; end if;
end $$;
reset role;
rollback;
