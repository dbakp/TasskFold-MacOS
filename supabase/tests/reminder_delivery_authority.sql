-- Dedicated disposable roles. Schema and all fixture mutations roll back.
begin;
insert into auth.users(id,email) values
 ('f0723000-0000-4000-8000-000000000001','taskfold-authority-one@example.invalid'),
 ('f0723000-0000-4000-8000-000000000002','taskfold-authority-two@example.invalid');
insert into auth.sessions(id,user_id) values
 ('f0723000-0000-4000-8000-000000000011','f0723000-0000-4000-8000-000000000001'),
 ('f0723000-0000-4000-8000-000000000012','f0723000-0000-4000-8000-000000000002');
insert into taskfold_private.reminder_authority_pilots values
 ('f0723000-0000-4000-8000-000000000001',clock_timestamp()+interval '5 minutes'),
 ('f0723000-0000-4000-8000-000000000002',clock_timestamp()+interval '5 minutes');
set local role anon;
do $$ begin
 begin perform public.taskfold_reminder_delivery_available(); raise exception 'Anonymous availability allowed'; exception when insufficient_privilege then null; end;
 begin perform public.taskfold_activate_reminder_device(gen_random_uuid(),repeat('a',64),1,'{}',0,gen_random_uuid()); raise exception 'Anonymous activation allowed'; exception when insufficient_privilege then null; end;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','f0723000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"f0723000-0000-4000-8000-000000000001","role":"authenticated","session_id":"f0723000-0000-4000-8000-000000000011"}',true);
do $$
declare binding jsonb:='{"platform":"ios","bundle":"com.dbakp.taskfold","environment":"development","token":"f0723000","time_zone":"Europe/Copenhagen","permission":"authorized","enabled":false}';
 device uuid:='f0723000-0000-4000-8000-000000000101'; nonce uuid:='f0723000-0000-4000-8000-000000000201';
 r jsonb; again jsonb; cutoff bigint:=floor(extract(epoch from clock_timestamp())*1000)::bigint+120000;
begin
 r:=public.taskfold_reminder_delivery_available();
 if r->>'available'<>'true' or r->>'account'<>auth.uid()::text then raise exception 'Own pilot unavailable'; end if;
 begin perform 1 from taskfold_private.reminder_authority_pilots; raise exception 'Private pilot rows readable'; exception when insufficient_privilege then null; end;
 begin perform 1 from taskfold_private.reminder_authority_rollout; raise exception 'Private rollout rows readable'; exception when insufficient_privilege then null; end;
 begin update taskfold_private.reminder_authority_rollout set enabled=true; raise exception 'Client enabled rollout'; exception when insufficient_privilege then null; end;
 begin insert into taskfold_private.reminder_authority_pilots values(gen_random_uuid(),now()); raise exception 'Client wrote pilot'; exception when insufficient_privilege then null; end;
 begin perform public.taskfold_activate_reminder_device(device,repeat('a',64),1,binding||'{"enabled":true}',cutoff,nonce);
  raise exception 'Active first enrollment accepted'; exception when others then if sqlerrm not like 'Enroll an inactive device%' then raise; end if; end;
 r:=public.taskfold_register_reminder_device(device,repeat('a',64),1,binding);
 if r->>'authority_version'<>'1' or r->>'server_time_ms' is null or r->'enabled_since_ms'<>'null'::jsonb then raise exception 'Inactive receipt lacks cutoff'; end if;
 begin perform public.taskfold_register_reminder_device(device,repeat('a',64),2,binding||'{"enabled":true}');
  raise exception 'Legacy activation bypassed handoff'; exception when others then if sqlerrm not like 'Use the current app%' then raise; end if; end;
 r:=public.taskfold_activate_reminder_device(device,repeat('a',64),2,binding||'{"enabled":true}',cutoff,nonce);
 if r->>'enabled'<>'true' or r->>'authority_nonce'<>nonce::text or (r->>'enabled_since_ms')::bigint<=cutoff then raise exception 'Activation did not enforce drained cutoff'; end if;
 again:=public.taskfold_activate_reminder_device(device,repeat('a',64),2,binding||'{"enabled":true}',cutoff,nonce);
 if r->'expires_at_ms'<>again->'expires_at_ms' or r->'enabled_since_ms'<>again->'enabled_since_ms' then raise exception 'Retry changed lease or cutoff'; end if;
 begin perform public.taskfold_activate_reminder_device(device,repeat('a',64),2,binding||'{"enabled":true}',cutoff,gen_random_uuid());
  raise exception 'Changed-nonce retry accepted'; exception when others then if sqlerrm not like 'TASKFOLD_DEVICE_CONFLICT:%' then raise; end if; end;
 begin perform public.taskfold_activate_reminder_device(device,repeat('a',64),3,binding||'{"enabled":true}',cutoff+600000,nonce);
  raise exception 'Unbounded future cutoff accepted'; exception when others then if sqlerrm<>'Invalid reminder delivery handoff.' then raise; end if; end;
end $$;
select set_config('request.jwt.claim.sub','f0723000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims','{"sub":"f0723000-0000-4000-8000-000000000002","role":"authenticated","session_id":"f0723000-0000-4000-8000-000000000012"}',true);
do $$ begin
 begin perform public.taskfold_activate_reminder_device('f0723000-0000-4000-8000-000000000101',repeat('b',64),3,
 '{"platform":"ios","bundle":"com.dbakp.taskfold","environment":"development","token":"f0723000","time_zone":"UTC","permission":"authorized","enabled":true}',0,gen_random_uuid());
 raise exception 'Outsider stole binding'; exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
 begin update taskfold_private.reminder_devices set authority_revision=null where id='f0723000-0000-4000-8000-000000000101';
 raise exception 'Partial authority metadata accepted'; exception when check_violation then null; end;
end $$;
set local role anon;
do $$ declare r jsonb; begin
 r:=public.taskfold_retire_reminder_device('f0723000-0000-4000-8000-000000000101',repeat('a',64),3);
 if r->>'enabled'<>'false' or r->>'authority_version'<>'1' or r->>'server_time_ms' is null or r->'account'<>'null'::jsonb then raise exception 'Retirement cutoff missing'; end if;
 r:=public.taskfold_retire_reminder_device('f0723000-0000-4000-8000-000000000102',repeat('a',64),1);
 if r->>'authority_version'<>'1' or r->>'server_time_ms' is null then raise exception 'Unknown retirement cutoff missing'; end if;
end $$;
reset role;
do $$ begin
 if exists(select 1 from taskfold_private.reminder_devices where id='f0723000-0000-4000-8000-000000000102') then raise exception 'Anonymous retirement inserted a row'; end if;
 update taskfold_private.reminder_authority_pilots set expires_at=clock_timestamp()-interval '1 minute' where user_id='f0723000-0000-4000-8000-000000000002';
end $$;
set local role authenticated;
do $$ begin
 if public.taskfold_reminder_delivery_available()->>'available'<>'false' then raise exception 'Expired pilot remains available'; end if;
end $$;
reset role;
update taskfold_private.reminder_authority_pilots set expires_at=clock_timestamp()+interval '1 minute' where user_id='f0723000-0000-4000-8000-000000000002';
set local role authenticated;
do $$ begin
 if public.taskfold_reminder_delivery_available()->>'available'<>'true' then raise exception 'Restored pilot unavailable'; end if;
end $$;
reset role;
delete from auth.sessions where id='f0723000-0000-4000-8000-000000000012';
set local role authenticated;
do $$ begin
 if public.taskfold_reminder_delivery_available()->>'available'<>'false' then raise exception 'Revoked session received availability'; end if;
end $$;
reset role;
select 'Reminder authority roles, cutoff, proof, replay, bounds, pilot expiry and session revocation passed' as result;
rollback;
