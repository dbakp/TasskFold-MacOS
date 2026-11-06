-- Disable this newly introduced service; preserve receipts for exact retry after reinstallation.
set local lock_timeout='3s';
do $preflight$ begin
 if (select md5(prosrc) from pg_proc where oid=to_regprocedure('taskfold_private.require_workflow_actor()')) is distinct from '70273382ab65699fe18e566d5cdc98d1' then raise exception using errcode='55000',message='The workflow service changed after rollout. Review rollback';end if;
 if (select md5(prosrc) from pg_proc where oid=to_regprocedure('taskfold_private.undo_private_workflow(uuid,jsonb)')) is distinct from 'e10df976dd4c01fddcaaf225f9f26898' then raise exception using errcode='55000',message='The workflow service changed after rollout. Review rollback';end if;
 if (select md5(prosrc) from pg_proc where oid=to_regprocedure('public.taskfold_undo_private_workflow(uuid,jsonb)')) is distinct from 'e5a12b7d563585344c89a1eeb5a59617' then raise exception using errcode='55000',message='The workflow service changed after rollout. Review rollback';end if;
 if (select md5(prosrc) from pg_proc where oid=to_regprocedure('public.taskfold_workflow_undo_capabilities()')) is distinct from 'b0cd499d5e2e06d955c7b2a77e7ce0f8' then raise exception using errcode='55000',message='The workflow service changed after rollout. Review rollback';end if;
end $preflight$;
drop function public.taskfold_workflow_undo_capabilities();
drop function public.taskfold_undo_private_workflow(uuid,jsonb);
revoke all on function taskfold_private.undo_private_workflow(uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function taskfold_private.require_workflow_actor() from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
