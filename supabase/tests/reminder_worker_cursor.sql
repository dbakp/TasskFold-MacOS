-- Global worker is inactive. All cursor changes and private device fixtures roll back.
begin;
insert into auth.users(id,email) values
 ('f8001000-0000-4000-8000-000000000001','taskfold-sweep-one@example.invalid'),
 ('f8001000-0000-4000-8000-000000000002','taskfold-sweep-two@example.invalid');
insert into auth.sessions(id,user_id) values
 ('f8001000-0000-4000-8000-000000000011','f8001000-0000-4000-8000-000000000001'),
 ('f8001000-0000-4000-8000-000000000012','f8001000-0000-4000-8000-000000000002');
insert into taskfold_private.reminder_authority_pilots(user_id,expires_at) values
 ('f8001000-0000-4000-8000-000000000001',clock_timestamp()+interval '5 minutes'),
 ('f8001000-0000-4000-8000-000000000002',clock_timestamp()+interval '5 minutes');
set local role anon;
do $$ begin
 begin perform public.taskfold_claim_reminder_sweep(); raise exception 'Anonymous sweep claim allowed'; exception when insufficient_privilege then null; end;
 begin perform public.taskfold_reminder_sweep_status(); raise exception 'Anonymous sweep metrics allowed'; exception when insufficient_privilege then null; end;
end $$;
set local role authenticated;
do $$ begin
 begin perform public.taskfold_claim_reminder_sweep(); raise exception 'Client sweep claim allowed'; exception when insufficient_privilege then null; end;
 begin perform public.taskfold_reminder_sweep_status(); raise exception 'Client sweep metrics allowed'; exception when insufficient_privilege then null; end;
 begin perform public.taskfold_finish_reminder_sweep(gen_random_uuid(),null,null,'processed','{}',0); raise exception 'Client sweep receipt allowed'; exception when insufficient_privilege then null; end;
 begin perform 1 from taskfold_private.reminder_worker_cursor; raise exception 'Client cursor table readable'; exception when insufficient_privilege then null; end;
 begin perform taskfold_private.invoke_reminder_worker(); raise exception 'Client Vault helper allowed'; exception when insufficient_privilege then null; end;
 begin perform public.taskfold_prepare_sweep_reminder_job(gen_random_uuid(),repeat('a',64),gen_random_uuid()); raise exception 'Client scheduled preparation allowed'; exception when insufficient_privilege then null; end;
end $$;
-- Actual inactive-first/activation contract, below the per-account quota, no provider requests.
do $$ declare owner uuid; session_key uuid; device uuid; binding jsonb; begin
 for i in 101..145 loop
  owner:=case when i<=130 then 'f8001000-0000-4000-8000-000000000001'::uuid else 'f8001000-0000-4000-8000-000000000002'::uuid end;
  session_key:=case when i<=130 then 'f8001000-0000-4000-8000-000000000011'::uuid else 'f8001000-0000-4000-8000-000000000012'::uuid end;
  perform set_config('request.jwt.claim.sub',owner::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner,'role','authenticated','session_id',session_key)::text,true);
  device:=('f8001000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid;
  binding:=jsonb_build_object('platform','ios','bundle','com.dbakp.taskfold','environment','development',
   'token',lpad(to_hex(i),4,'0'),'time_zone','Europe/Copenhagen','permission','authorized','enabled',false);
  perform public.taskfold_register_reminder_device(device,repeat('c',64),1,binding);
  perform public.taskfold_activate_reminder_device(device,repeat('c',64),2,binding||'{"enabled":true}',
   floor(extract(epoch from clock_timestamp())*1000)::bigint,gen_random_uuid());
 end loop;
 perform set_config('request.jwt.claim.sub','f8001000-0000-4000-8000-000000000001',true);
 perform set_config('request.jwt.claims','{"sub":"f8001000-0000-4000-8000-000000000001","role":"authenticated","session_id":"f8001000-0000-4000-8000-000000000011"}',true);
end $$;
insert into public.tasks(id,user_id,title,description,task_generation,reminder_specs) values
 ('f8001000-0000-4000-8000-000000000201',auth.uid(),'Sweep fixture title','Never in cursor metrics',gen_random_uuid(),
  jsonb_build_array(jsonb_build_object('version',1,'id','f8001000-0000-4000-8000-000000000301','kind','absolute',
   'at',to_char(timezone('UTC',clock_timestamp()+interval '300 milliseconds'),'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
   'time_zone','UTC','channels',jsonb_build_array('local'),'enabled',true)));
set local role service_role;
do $$
declare r jsonb; old_nonce uuid; fresh_nonce uuid;
 a uuid:='00000000-0000-4000-8000-000000000021'; b uuid:='00000000-0000-4000-8000-000000000040';
 counts jsonb:='{"devices":20,"accepted":2,"retry":1,"failed":1,"obsolete":1,"receiptRejected":0}';
 metrics jsonb; item jsonb; job jsonb;
begin
 begin perform taskfold_private.invoke_reminder_worker(); raise exception 'Service can read Vault helper'; exception when insufficient_privilege then null; end;
 update taskfold_private.reminder_worker_cursor set cursor=null,lease=null,lease_until=null,retry_at='-infinity',
  sweep_started_at=null,last_sweep_finished_at=null,completed_sweeps=0,last_status='idle',last_counts='{}' where singleton;
 r:=public.taskfold_claim_reminder_sweep();
 if r->>'version'<>'1' or r->'after'<>'null'::jsonb or r->>'lease' is null then raise exception 'Initial sweep lease incorrect'; end if;
 old_nonce:=(r->>'lease')::uuid;
 perform public.taskfold_reconcile_reminder_jobs('f8001000-0000-4000-8000-000000000101');
 perform pg_sleep(0.5);
 job:=public.taskfold_claim_reminder_jobs('f8001000-0000-4000-8000-000000000101',1)->0;
 if job is null then raise exception 'Sweep payload fixture did not become due'; end if;
 if public.taskfold_prepare_sweep_reminder_job(old_nonce,job->>'id',(job->>'lease')::uuid) is null then raise exception 'Current sweep could not prepare valid job'; end if;
 if public.taskfold_prepare_sweep_reminder_job(gen_random_uuid(),job->>'id',(job->>'lease')::uuid) is not null then raise exception 'Wrong sweep obtained private payload'; end if;
 if public.taskfold_claim_reminder_sweep() is not null then raise exception 'Two live sweeps accepted'; end if;
 if public.taskfold_finish_reminder_sweep(gen_random_uuid(),null,b,'processed',counts,0) then raise exception 'Wrong nonce accepted'; end if;
 if public.taskfold_finish_reminder_sweep(old_nonce,a,b,'processed',counts,0) then raise exception 'Wrong baseline accepted'; end if;
 for item in select value from jsonb_array_elements('[{}, {"devices":21,"accepted":0,"retry":0,"failed":0,"obsolete":0,"receiptRejected":0}, {"devices":0,"accepted":81,"retry":0,"failed":0,"obsolete":0,"receiptRejected":0}, {"devices":0,"accepted":1.5,"retry":0,"failed":0,"obsolete":0,"receiptRejected":0}, {"devices":0,"accepted":0,"retry":0,"failed":0,"obsolete":0,"receiptRejected":0,"notes":"PRIVATE"}]') loop
  begin perform public.taskfold_finish_reminder_sweep(old_nonce,null,b,'processed',item,0); raise exception 'Invalid counts accepted';
   exception when others then if sqlerrm not like 'Invalid reminder sweep%' then raise; end if; end;
 end loop;
 begin perform public.taskfold_finish_reminder_sweep(old_nonce,null,b,'error',counts,30); raise exception 'Error advanced cursor';
  exception when others then if sqlerrm<>'Invalid reminder sweep progress.' then raise; end if; end;
 if not public.taskfold_finish_reminder_sweep(old_nonce,null,b,'processed',counts,0) then raise exception 'First page did not commit'; end if;
 if public.taskfold_finish_reminder_sweep(old_nonce,null,null,'error',counts,30) then raise exception 'Late error rewound committed cursor'; end if;
 r:=public.taskfold_claim_reminder_sweep(); fresh_nonce:=(r->>'lease')::uuid;
 if r->>'after'<>b::text or fresh_nonce=old_nonce then raise exception 'Restart lost cursor or nonce'; end if;
 if public.taskfold_finish_reminder_sweep(old_nonce,null,null,'processed',counts,0) then raise exception 'Old lease completed replacement'; end if;
 begin perform public.taskfold_finish_reminder_sweep(fresh_nonce,b,a,'processed',counts,0); raise exception 'Backward cursor accepted';
  exception when others then if sqlerrm<>'Invalid reminder sweep progress.' then raise; end if; end;
 begin perform public.taskfold_finish_reminder_sweep(fresh_nonce,b,b,'processed',counts,0); raise exception 'Unchanged processed cursor accepted';
  exception when others then if sqlerrm<>'Invalid reminder sweep progress.' then raise; end if; end;
 begin perform public.taskfold_finish_reminder_sweep(fresh_nonce,b,null,'paused',counts,0); raise exception 'Paused run wrapped sweep';
  exception when others then if sqlerrm<>'Invalid reminder sweep progress.' then raise; end if; end;
 begin perform public.taskfold_finish_reminder_sweep(fresh_nonce,b,b,'paused',counts,3601); raise exception 'Unbounded retry accepted';
  exception when others then if sqlerrm<>'Invalid reminder sweep receipt.' then raise; end if; end;
 if not public.taskfold_finish_reminder_sweep(fresh_nonce,b,b,'paused',counts,900) then raise exception 'Provider pause receipt failed'; end if;
 if public.taskfold_claim_reminder_sweep() is not null then raise exception 'Global provider backoff ignored'; end if;
 metrics:=public.taskfold_reminder_sweep_status();
 if metrics->>'last_status'<>'paused' or metrics->>'completed_sweeps'<>'0' or metrics->'last_sweep_finished_at'<>'null'::jsonb or
  (metrics-array['version','running','retry_at','sweep_started_at','last_sweep_finished_at','completed_sweeps','last_started_at','last_finished_at','last_status','last_counts'])<>'{}'::jsonb then raise exception 'Sweep diagnostics leak cursor or invent completion'; end if;
 -- Simulate time expiry on the isolated, rolled-back scheduler row, never an actual device/job.
 update taskfold_private.reminder_worker_cursor set retry_at='-infinity' where singleton;
 r:=public.taskfold_claim_reminder_sweep(); old_nonce:=(r->>'lease')::uuid;
 update taskfold_private.reminder_worker_cursor set lease_until=clock_timestamp()-interval '1 second' where singleton;
 if public.taskfold_prepare_sweep_reminder_job(old_nonce,job->>'id',(job->>'lease')::uuid) is not null then raise exception 'Expired sweep obtained private payload'; end if;
 if public.taskfold_finish_reminder_sweep(old_nonce,b,null,'processed',counts,0) then raise exception 'Expired sweep receipt accepted'; end if;
 r:=public.taskfold_claim_reminder_sweep(); fresh_nonce:=(r->>'lease')::uuid;
 if fresh_nonce=old_nonce or r->>'after'<>b::text then raise exception 'Expired lease did not preserve prior cursor'; end if;
 if not public.taskfold_finish_reminder_sweep(fresh_nonce,b,null,'processed',counts,0) then raise exception 'Exhausted page did not wrap'; end if;
 metrics:=public.taskfold_reminder_sweep_status();
 if metrics->>'completed_sweeps'<>'1' or metrics->'last_sweep_finished_at'='null'::jsonb or metrics->'sweep_started_at'<>'null'::jsonb then raise exception 'Sweep completion metadata incorrect'; end if;
 r:=public.taskfold_claim_reminder_sweep();
 if r->'after'<>'null'::jsonb then raise exception 'Next sweep did not start at beginning'; end if;
 if not public.taskfold_finish_reminder_sweep((r->>'lease')::uuid,null,null,'paused',counts,0) then raise exception 'Initial pause receipt failed'; end if;
 if (public.taskfold_reminder_sweep_status()->>'completed_sweeps')<>'1' then raise exception 'Initial pause invented completed sweep'; end if;
end $$;
do $$ declare r jsonb; page jsonb; count int; after uuid; next uuid; visited uuid[]:='{}'; counts jsonb; item text; begin
 update taskfold_private.reminder_worker_cursor set cursor=null,lease=null,lease_until=null,retry_at='-infinity',sweep_started_at=null where singleton;
 for i in 1..3 loop
  r:=public.taskfold_claim_reminder_sweep(); after:=(r->>'after')::uuid;
  page:=public.taskfold_reminder_device_page(after,20); count:=jsonb_array_length(page);
  if count<>(case when i<3 then 20 else 5 end) then raise exception 'Real device page count incorrect'; end if;
  for item in select value from jsonb_array_elements_text(page) loop visited:=array_append(visited,item::uuid); end loop;
  next:=case when count=20 then (page->>(count-1))::uuid else null end;
  counts:=jsonb_build_object('devices',count,'accepted',0,'retry',0,'failed',0,'obsolete',0,'receiptRejected',0);
  if not public.taskfold_finish_reminder_sweep((r->>'lease')::uuid,after,next,'processed',counts,0) then raise exception 'Real device page receipt failed'; end if;
  if i=1 then delete from taskfold_private.reminder_devices where id=next; end if;
 end loop;
 if cardinality(visited)<>45 or cardinality(array(select distinct unnest(visited)))<>45 or visited[45]<>'f8001000-0000-4000-8000-000000000145'::uuid then raise exception 'Later devices starved'; end if;
 r:=public.taskfold_claim_reminder_sweep(); if r->'after'<>'null'::jsonb then raise exception 'Real device sweep did not wrap'; end if;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from cron.job where jobname='taskfold-native-reminder-sweep' and not active and schedule='30 seconds' and command='select taskfold_private.invoke_reminder_worker();') then raise exception 'Native cron not disabled or owned'; end if;
 -- Hide only configuration metadata within this transaction; secret values are never read.
 perform vault.update_secret(id,new_name:='taskfold-sweep-fixture-hidden-url') from vault.secrets where name='taskfold_reminder_project_url';
 begin perform taskfold_private.invoke_reminder_worker(); raise exception 'Missing Vault configuration invoked network';
  exception when others then if sqlerrm<>'Native reminder scheduler is not configured.' then raise; end if; end;
end $$;
select 'reminder sweep role, lease, cursor, expiry, retry, diagnostics and inactive cron checks passed' as result;
rollback;
