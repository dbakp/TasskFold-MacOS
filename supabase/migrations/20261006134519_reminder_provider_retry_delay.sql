-- Provider retry hints cannot shorten the queue's exponential backoff. Existing three-argument
-- receipts remain compatible; the native APNs worker uses this service-only invoker wrapper.
create function public.taskfold_finish_reminder_delivery(_id text, _lease uuid, _outcome text, _retry_after_seconds int default null)
returns boolean language plpgsql security invoker set search_path='' as $$
declare accepted boolean;
begin
 if _retry_after_seconds is not null and (_outcome<>'transient' or _retry_after_seconds not between 0 and 3600) then
  raise exception 'Invalid provider retry delay.';
 end if;
 accepted:=taskfold_private.finish_reminder_job(_id,_lease,_outcome);
 if accepted and _outcome='transient' and _retry_after_seconds is not null then
  -- finish holds the device/job row locks until this transaction commits. A stale receipt
  -- cannot defer a replacement lease, retire a refreshed binding or resurrect a cancellation.
  update taskfold_private.reminder_jobs set next_attempt=greatest(next_attempt,clock_timestamp()+_retry_after_seconds*interval '1 second')
   where id=_id and state='pending';
 end if;
 return accepted;
end $$;
revoke all on function public.taskfold_finish_reminder_delivery(text,uuid,text,int) from public,anon,authenticated;
grant execute on function public.taskfold_finish_reminder_delivery(text,uuid,text,int) to service_role;
