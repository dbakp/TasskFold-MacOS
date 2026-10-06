-- Run on connection A, with the native cron inactive. Run reminder_sweep_compete.sql on
-- a separately established connection B during the hold. All cursor state rolls back.
begin;
do $$ begin
 if exists(select 1 from cron.job where jobname='taskfold-native-reminder-sweep' and active)
 then raise exception 'Native cron must be inactive for this test.'; end if;
end $$;
set local role service_role;
do $$ declare r jsonb; begin
 r:=public.taskfold_claim_reminder_sweep();
 if r is null then raise exception 'Coordinator must be idle for this test.'; end if;
 perform pg_catalog.pg_advisory_xact_lock(643332100::bigint);
end $$;
select pg_catalog.pg_sleep(40);
select exists(select 1 from taskfold_private.reminder_worker_cursor
 where lease_until>clock_timestamp()) as holder_has_lease;
rollback;
