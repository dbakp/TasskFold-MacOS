-- Keep enrollment/list/revocation bounded like cancellation and task operations.
-- PostgREST hoists the public wrapper's statement timeout before the RPC query.
-- The private lock deadline also covers the shared account advisory mutex.
alter function taskfold_private.automation_manage(uuid,uuid,text,jsonb) set lock_timeout='3s';
alter function public.taskfold_automation_keys(uuid,uuid,text,jsonb) set statement_timeout='10s';
