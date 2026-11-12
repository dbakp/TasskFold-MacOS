-- Reduce Disk IO from pg_cron (12 November 2026).
--
-- 1. Remove the legacy 'check-due-tasks-every-minute' job (from 20251202205047).
--    It posts to check-due-tasks with only the anon key, but the hardened handler
--    requires the x-cron-secret header, so every call has returned 401 and done no
--    work. It still wrote a cron log row and an HTTP response row every minute.
--    Reminder delivery is unaffected: the job never delivered anything.
-- 2. Empty cron.job_run_details. TRUNCATE is near-instant and avoids the heavy IO of
--    deleting a year of per-minute rows one by one. Only run history is lost.
-- 3. Keep 7 days of cron run history from now on with a daily retention job.

do $$
begin
  if exists (select 1 from cron.job where jobname = 'check-due-tasks-every-minute') then
    perform cron.unschedule('check-due-tasks-every-minute');
  end if;
end $$;

truncate table cron.job_run_details;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'taskfold-cron-log-retention') then
    perform cron.unschedule('taskfold-cron-log-retention');
  end if;
  perform cron.schedule(
    'taskfold-cron-log-retention',
    '43 3 * * *',
    $job$delete from cron.job_run_details where end_time < now() - interval '7 days'$job$
  );
end $$;
