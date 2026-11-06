-- Read-only synthetic control; no accounts/tasks/jobs are written.
with fixtures(name,spec) as (
 values
 ('interval-v3','{"version":3,"id":"11000000-0000-4000-8000-000000000001","kind":"interval","enabled":true,"channels":["local"],"interval_schedule":{"start_ms":1792652400000,"every_minutes":30,"count":3,"until_ms":null}}'::jsonb),
 ('relative-control','{"version":1,"id":"11000000-0000-4000-8000-000000000002","kind":"relative","anchor":"planned","offset_minutes":0,"enabled":true,"channels":["local"]}'::jsonb)
), tasks as (
 select name, '{"id":"22000000-0000-4000-8000-000000000001","task_generation":"22000000-0000-4000-8000-000000000002","completed":false,"completion_version":0,"due_date":"2026-10-22","due_time":"09:00","time_zone":"Europe/Copenhagen"}'::jsonb
 || jsonb_build_object('reminder_specs',jsonb_build_array(spec)) as task from fixtures
)
select name, (select count(*) from taskfold_private.reminder_events_window(task,'Europe/Copenhagen','2026-10-21T00:00:00Z'::timestamptz,'2026-10-24T00:00:00Z'::timestamptz)) as server_events from tasks;
-- Expected: interval-v3 = 0; relative-control = 1.
