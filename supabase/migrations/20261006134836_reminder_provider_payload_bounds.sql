-- Minimize transient provider content: bounded title and a generic prompt, never task notes.
create or replace function taskfold_private.prepare_reminder_job(_id text,_lease uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare j taskfold_private.reminder_jobs; d taskfold_private.reminder_devices; t public.tasks; event_id text; provider_id text;
begin
 select * into j from taskfold_private.reminder_jobs where id=_id;
 if not found then return null; end if;
 select * into d from taskfold_private.reminder_devices where id=j.device_id for update;
 select * into j from taskfold_private.reminder_jobs where id=_id for update;
 if not found or j.state<>'leased' or _lease is null or j.lease_token<>_lease or j.lease_until<=clock_timestamp() or not taskfold_private.reminder_job_current(j) then return null; end if;
 select * into t from public.tasks where id=j.task_id;
 event_id:=t.id::text||case when t.reminder_specs='[]'::jsonb then '' else '.'||j.spec_id::text end;
 provider_id:=substr(j.id,1,8)||'-'||substr(j.id,9,4)||'-5'||substr(j.id,14,3)||'-a'||substr(j.id,18,3)||'-'||substr(j.id,21,12);
 return jsonb_build_object('id',j.id,'provider_id',provider_id,'collapse_id',j.id,'binding',d.binding,
  'content',jsonb_build_object('title',left(t.title,128),'body','Open Taskfold to review this task.','category','taskfold.reminder',
   'info',jsonb_build_object('eventKind','task','eventID',event_id,'accountID',j.user_id,'taskID',j.task_id,'specID',j.spec_id,'signature',j.signature,
    'originalAt',extract(epoch from j.fire_at),'fireAt',extract(epoch from j.fire_at),'snoozed',false)));
end $$;
