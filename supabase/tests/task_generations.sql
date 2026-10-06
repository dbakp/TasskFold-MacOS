-- Disposable, rollback-only identity and catch-up checks. No provider requests.
begin;
insert into auth.users(id,email,raw_user_meta_data) values('f6010000-0000-4000-8000-000000000001','taskfold-generation@example.invalid','{}');
insert into auth.sessions(id,user_id) values('f6010000-0000-4000-8000-000000000011','f6010000-0000-4000-8000-000000000001');
select set_config('request.jwt.claim.sub','f6010000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"f6010000-0000-4000-8000-000000000001","session_id":"f6010000-0000-4000-8000-000000000011"}',true);
set local role authenticated;
select public.taskfold_register_reminder_device('f6010000-0000-4000-8000-000000000021',repeat('c',64),1,'{"platform":"ios","bundle":"com.dbakp.taskfold","environment":"development","token":"cc33","time_zone":"UTC","permission":"authorized","enabled":false}');
select public.taskfold_register_reminder_device('f6010000-0000-4000-8000-000000000021',repeat('c',64),2,'{"platform":"ios","bundle":"com.dbakp.taskfold","environment":"development","token":"cc33","time_zone":"UTC","permission":"authorized","enabled":true}');
insert into public.tasks(id,user_id,title,created_at,task_generation,reminder_specs) values
 ('f6010000-0000-4000-8000-000000000041',auth.uid(),'Backdated import fixture',now()-interval '1 year','f6010000-0000-4000-8000-000000000051',jsonb_build_array(jsonb_build_object('version',1,'id','11111111-1111-4111-8111-111111111111','kind','absolute','at',to_char(timezone('UTC',now()-interval '1 minute'),'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),'time_zone','UTC','channels',jsonb_build_array('push'),'enabled',true)));
reset role;
set local role service_role;
do $$ begin
 if public.taskfold_reconcile_reminder_jobs('f6010000-0000-4000-8000-000000000021')->>'queued'<>'0' then raise exception 'Backdated import replayed an already-past reminder'; end if;
end $$;
reset role;
set local role authenticated;
insert into public.tasks(id,user_id,title,task_generation,reminder_specs) values
 ('f6010000-0000-4000-8000-000000000042',auth.uid(),'Identity fixture','f6010000-0000-4000-8000-000000000052',jsonb_build_array(jsonb_build_object('version',1,'id','11111111-1111-4111-8111-111111111111','kind','absolute','at',to_char(timezone('UTC',clock_timestamp()+interval '300 milliseconds'),'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),'time_zone','UTC','channels',jsonb_build_array('local'),'enabled',true)));
reset role;
set local role service_role;
do $$ declare job jsonb; begin
 if public.taskfold_reconcile_reminder_jobs('f6010000-0000-4000-8000-000000000021')->>'queued'<>'1' then raise exception 'Future eligible occurrence not queued'; end if;
 perform pg_sleep(0.4);
 job:=public.taskfold_claim_reminder_jobs('f6010000-0000-4000-8000-000000000021',25)->0;
 if not public.taskfold_finish_reminder_job(job->>'id',(job->>'lease')::uuid,'accepted') then raise exception 'Eligible catch-up not accepted'; end if;
end $$;
reset role;
set local role authenticated;
do $$ declare old public.tasks; restored public.tasks; old_signature text; new_signature text; base jsonb; begin
 select * into old from public.tasks where id='f6010000-0000-4000-8000-000000000042';
 base:=to_jsonb(old);
 perform public.taskfold_delete_task(old.id,base);
 begin
  insert into public.tasks select old.*;
  raise exception 'Deleted identity replay accepted';
 exception when others then
  if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if;
 end;
 old.task_generation:='f6010000-0000-4000-8000-000000000062';
 insert into public.tasks select old.*;
 select * into restored from public.tasks where id=old.id;
 if restored.completion_version<>0 then raise exception 'Restore reused an old completion cycle'; end if;
 begin
  perform public.taskfold_patch_task(old.id,base,jsonb_build_object('title','Stale offline title'));
  raise exception 'Old title baseline accepted';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 begin
  perform public.taskfold_delete_task(old.id,base);
  raise exception 'Old deletion baseline accepted';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 begin
  update public.tasks set task_generation='f6010000-0000-4000-8000-000000000072' where id=old.id;
  raise exception 'Mutable generation accepted';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 restored:=public.taskfold_patch_task(old.id,to_jsonb(restored),jsonb_build_object('title','Reviewed restored title'));
 if restored.title<>'Reviewed restored title' then raise exception 'Reviewed edit failed'; end if;
 insert into public.tasks select restored.* on conflict(id) do nothing;
end $$;
-- A device first enabled after the occurrence's time cannot catch up the old schedule.
select public.taskfold_register_reminder_device('f6010000-0000-4000-8000-000000000022',repeat('d',64),1,'{"platform":"macos","bundle":"com.dbakp.taskfold.mac","environment":"production","token":"dd44","time_zone":"UTC","permission":"authorized","enabled":false}');
select public.taskfold_register_reminder_device('f6010000-0000-4000-8000-000000000022',repeat('d',64),2,'{"platform":"macos","bundle":"com.dbakp.taskfold.mac","environment":"production","token":"dd44","time_zone":"UTC","permission":"authorized","enabled":true}');
reset role;
set local role service_role;
do $$ declare old_signature text; current_signature text; epoch timestamptz; begin
 if public.taskfold_reconcile_reminder_jobs('f6010000-0000-4000-8000-000000000021')->>'queued'<>'0' or public.taskfold_reconcile_reminder_jobs('f6010000-0000-4000-8000-000000000022')->>'queued'<>'0' then raise exception 'Restore or new opt-in replayed an accepted past event'; end if;
 if (select count(*) from taskfold_private.reminder_jobs where task_id='f6010000-0000-4000-8000-000000000042' and state='sent')<>1 then raise exception 'Delete removed accepted receipt'; end if;
 select signature into old_signature from taskfold_private.reminder_jobs where task_id='f6010000-0000-4000-8000-000000000042' and state='sent';
 select e.signature into current_signature from public.tasks t cross join lateral taskfold_private.reminder_events(to_jsonb(t),'UTC') e where t.id='f6010000-0000-4000-8000-000000000042';
 if old_signature=current_signature then raise exception 'Recreation reused signature'; end if;
 if (select count(*) from taskfold_private.task_generations where task_id='f6010000-0000-4000-8000-000000000042')<>2 then raise exception 'Create-only retry changed generation ledger'; end if;
 if exists(select 1 from taskfold_private.task_generations where task_id='f6010000-0000-4000-8000-000000000042' and generation='f6010000-0000-4000-8000-000000000052' and deleted_at is null) then raise exception 'Deleted generation lost tombstone'; end if;
 select enabled_since into epoch from taskfold_private.reminder_devices where id='f6010000-0000-4000-8000-000000000021';
 update taskfold_private.reminder_devices set revision=revision+1,binding=jsonb_set(binding,'{token}','"cc55"') where id='f6010000-0000-4000-8000-000000000021';
 if (select enabled_since from taskfold_private.reminder_devices where id='f6010000-0000-4000-8000-000000000021')<>epoch then raise exception 'Token refresh erased continuity'; end if;
end $$;
reset role;
do $$ begin
 if has_table_privilege('authenticated','taskfold_private.task_generations','select') or has_function_privilege('authenticated','taskfold_private.guard_task_generation()','execute') then raise exception 'Generation privacy boundary incorrect'; end if;
end $$;
rollback;
