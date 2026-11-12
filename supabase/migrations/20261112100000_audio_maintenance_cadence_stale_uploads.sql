-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- 1. Cadence. A tick every minute costs Disk IO for work whose shortest wait is
-- minutes (retired media is removed after a 5 minute grace, upload probes are
-- spaced 2 minutes apart, cleanup claims live 2 minutes). Every 15 minutes still
-- purges retired media within about 20 minutes and keeps the one-use HMAC
-- admission unchanged (the proof is issued per tick, valid for 90 seconds).
-- The job stays in whatever active/inactive state it already has.
do $$declare job bigint;begin
 select jobid into job from cron.job where jobname='taskfold-audio-maintenance';
 if job is null then raise exception 'Audio maintenance scheduler job is unavailable.';end if;
 perform cron.alter_job(job,schedule:='*/15 * * * *');
end$$;

-- 2. Stale upload fence. An 'open' upload attempt on a retired publication blocked
-- Storage cleanup, and kept counting against the author/task quota, forever when
-- the upload never reached Storage (a failed or aborted request): absence is not
-- terminal evidence while the request might still land. That is only true for a
-- bounded time. The gateway abandons an upload after 30 seconds at the latest and
-- Storage accepts at most 8 MB, so no request started more than one hour ago can
-- still land. After that fence the attempt is settled so cleanup claims the
-- object path, deletes whatever is there, verifies absence and purges the row.
-- A late object is therefore still removed, never kept; younger attempts keep the
-- existing fence and probe behaviour untouched.
create function taskfold_private.audio_upload_fence() returns interval
language sql immutable set search_path='' as $$select interval '1 hour'$$;
revoke all on function taskfold_private.audio_upload_fence() from public,anon,authenticated,service_role;

alter function taskfold_private.audio_maintenance(text,jsonb) rename to audio_maintenance_before_stale_fence;
revoke all on function taskfold_private.audio_maintenance_before_stale_fence(text,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.audio_maintenance(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$begin
 if action='claim' then
  perform taskfold_private.audio_fields(b,array[]::text[]);
  -- Retire expired reservations first so their abandoned attempts are eligible too.
  perform taskfold_private.audio_comment_gateway_v2('cleanup',null,null,'{}');
  update taskfold_private.audio_upload_attempts u set state='settled',settled_at=clock_timestamp()
   from taskfold_private.audio_comment_publications p
   where p.operation_id=u.operation_id and p.state='retired' and u.state='open'
    and u.started_at<clock_timestamp()-taskfold_private.audio_upload_fence();
 end if;
 return taskfold_private.audio_maintenance_before_stale_fence(action,b);
end$$;
revoke all on function taskfold_private.audio_maintenance(text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_maintenance(text,jsonb) to service_role;
create or replace function public.taskfold_audio_comment_maintenance(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_maintenance(_action,_body)$$;
revoke all on function public.taskfold_audio_comment_maintenance(text,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_maintenance(text,jsonb) to service_role;

commit;
