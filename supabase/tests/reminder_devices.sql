-- Disposable identities, sessions and APNs-shaped addresses; no provider requests; all rolled back.
begin;
insert into auth.users(id) values ('fd229de1-c5b4-4f06-a4e1-e6a329310901'),('fd229de1-c5b4-4f06-a4e1-e6a329310902');
insert into auth.sessions(id,user_id) values
('fd229de1-c5b4-4f06-a4e1-e6a329310911','fd229de1-c5b4-4f06-a4e1-e6a329310901'),
('fd229de1-c5b4-4f06-a4e1-e6a329310912','fd229de1-c5b4-4f06-a4e1-e6a329310902');
set local role authenticated;
set local request.jwt.claim.sub = 'fd229de1-c5b4-4f06-a4e1-e6a329310901';
set local request.jwt.claims = '{"sub":"fd229de1-c5b4-4f06-a4e1-e6a329310901","role":"authenticated","session_id":"fd229de1-c5b4-4f06-a4e1-e6a329310911"}';
do $$
declare d uuid := 'fd229de1-c5b4-4f06-a4e1-e6a329310921'; s text := repeat('a',64); r jsonb; old jsonb; b jsonb := jsonb_build_object('platform','ios','bundle','com.dbakp.taskfold','environment','development','token',repeat('b',64),'time_zone','Europe/Copenhagen','permission','authorized','enabled',false);
begin
  begin perform public.taskfold_register_reminder_device(d,s,1,b||'{"enabled":true}'); raise exception 'Active first enrollment accepted'; exception when others then if sqlerrm not like 'Enroll an inactive%' then raise; end if; end;
  r := public.taskfold_register_reminder_device(d,s,1,b);
  if r->>'revision'<>'1' or r->>'enabled'<>'false' or r->>'account'<>'fd229de1-c5b4-4f06-a4e1-e6a329310901' or r->>'state'<>'registered' then raise exception 'Enrollment receipt incorrect'; end if;
  if (r-array['version','device','revision','account','state','enabled','expires_at_ms','authority_version','server_time_ms','enabled_since_ms','authority_nonce'])<>'{}'::jsonb then raise exception 'Receipt leaked private data'; end if;
  old := public.taskfold_register_reminder_device(d,s,1,b); if (old-'server_time_ms')<>(r-'server_time_ms') then raise exception 'Retry renewed lease'; end if;
  r := public.taskfold_register_reminder_device(d,s,2,b||'{"enabled":true}'); if r->>'enabled'<>'true' then raise exception 'Activation failed'; end if;
  begin perform public.taskfold_register_reminder_device(d,s,1,b); raise exception 'Old registration accepted'; exception when others then if sqlerrm not like 'TASKFOLD_DEVICE_CONFLICT:%' then raise; end if; end;
  begin perform public.taskfold_register_reminder_device(d,s,2,b); raise exception 'Changed same-revision retry accepted'; exception when others then if sqlerrm not like 'TASKFOLD_DEVICE_CONFLICT:%' then raise; end if; end;
  begin perform public.taskfold_register_reminder_device(d,repeat('c',64),3,b); raise exception 'Wrong proof accepted'; exception when insufficient_privilege then null; end;
  begin perform 1 from taskfold_private.reminder_devices; raise exception 'Private tokens readable'; exception when insufficient_privilege then null; end;
  begin perform public.taskfold_register_reminder_device(d,s,3,b||'{"environment":"sandbox"}'); raise exception 'Unknown environment accepted'; exception when others then if sqlerrm<>'Invalid device binding document.' then raise; end if; end;
  begin perform public.taskfold_register_reminder_device(d,s,3,b||'{"time_zone":"Mars/City"}'); raise exception 'Invalid zone accepted'; exception when others then if sqlerrm<>'Invalid device binding document.' then raise; end if; end;
  begin perform public.taskfold_register_reminder_device(d,s,3,b||'{"token":"bbbbb"}'); raise exception 'Odd token accepted'; exception when others then if sqlerrm<>'Invalid device binding document.' then raise; end if; end;
  begin perform public.taskfold_register_reminder_device(d,s,3,b||'{"bundle":"com.attacker"}'); raise exception 'Wrong bundle accepted'; exception when others then if sqlerrm<>'Invalid device binding document.' then raise; end if; end;
  begin perform public.taskfold_register_reminder_device(d,s,3,b||'{"permission":"denied","enabled":true}'); raise exception 'Denied device activated'; exception when others then if sqlerrm<>'Invalid device binding document.' then raise; end if; end;
  r:=public.taskfold_register_reminder_device(d,s,3,b||jsonb_build_object('token',repeat('d',64),'enabled',true)); if r->>'revision'<>'3' then raise exception 'Token rotation failed'; end if;
  perform public.taskfold_register_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310922',repeat('e',64),1,b);
  begin perform public.taskfold_register_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310923',repeat('f',64),1,b); raise exception 'Duplicate push address accepted'; exception when others then if sqlerrm not like 'This push address is already registered.%' then raise; end if; end;
end $$;
set local request.jwt.claim.sub = 'fd229de1-c5b4-4f06-a4e1-e6a329310902';
set local request.jwt.claims = '{"sub":"fd229de1-c5b4-4f06-a4e1-e6a329310902","role":"authenticated","session_id":"fd229de1-c5b4-4f06-a4e1-e6a329310912"}';
do $$
declare b jsonb := jsonb_build_object('platform','macos','bundle','com.dbakp.taskfold.mac','environment','production','token',repeat('d',64),'time_zone','America/New_York','permission','provisional','enabled',true); r jsonb;
begin
  begin perform public.taskfold_register_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310921',repeat('b',64),4,b); raise exception 'Outsider took binding'; exception when insufficient_privilege then null; end;
  r:=public.taskfold_register_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310921',repeat('a',64),4,b);
  if r->>'account'<>'fd229de1-c5b4-4f06-a4e1-e6a329310902' then raise exception 'Capability account switch failed'; end if;
end $$;
set local role anon;
set local request.jwt.claim.sub = '';
set local request.jwt.claims = '{}';
do $$ declare r jsonb; begin
  begin perform public.taskfold_register_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310921',repeat('a',64),5,'{}'); raise exception 'Anonymous enrollment accepted'; exception when insufficient_privilege then null; end;
  begin perform public.taskfold_retire_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310921',repeat('b',64),5); raise exception 'Anonymous wrong-proof revocation accepted'; exception when insufficient_privilege then null; end;
  r:=public.taskfold_retire_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310921',repeat('a',64),5);
  if r->>'enabled'<>'false' or r->>'state'<>'retired' or r->'account'<>'null'::jsonb then raise exception 'Retirement did not clear scope'; end if;
  if (public.taskfold_retire_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310921',repeat('a',64),5)-'server_time_ms')<>(r-'server_time_ms') then raise exception 'Retirement retry changed receipt'; end if;
  perform public.taskfold_retire_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310924',repeat('a',64),2);
end $$;
set local role authenticated;
set local request.jwt.claim.sub = 'fd229de1-c5b4-4f06-a4e1-e6a329310901';
set local request.jwt.claims = '{"sub":"fd229de1-c5b4-4f06-a4e1-e6a329310901","role":"authenticated","session_id":"fd229de1-c5b4-4f06-a4e1-e6a329310911"}';
do $$ declare b jsonb:=jsonb_build_object('platform','ios','bundle','com.dbakp.taskfold','environment','development','token',repeat('d',64),'time_zone','UTC','permission','authorized','enabled',true); begin
  begin perform public.taskfold_register_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310921',repeat('a',64),4,b); raise exception 'Retired binding reactivated by late old command'; exception when others then if sqlerrm not like 'TASKFOLD_DEVICE_CONFLICT:%' then raise; end if; end;
  perform public.taskfold_register_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310921',repeat('a',64),6,b);
end $$;
do $$ declare i int; b jsonb := jsonb_build_object('platform','ios','bundle','com.dbakp.taskfold','environment','development','token','00','time_zone','UTC','permission','authorized','enabled',false); begin
  for i in 1..30 loop
    perform public.taskfold_register_reminder_device(gen_random_uuid(),repeat('a',64),1,b||jsonb_build_object('token',lpad(to_hex(i),64,'0')));
  end loop;
  begin perform public.taskfold_register_reminder_device(gen_random_uuid(),repeat('a',64),1,b); raise exception 'Device quota bypassed'; exception when others then if sqlerrm<>'This account has reached its limit of 32 registered devices.' then raise; end if; end;
end $$;
reset role;
do $$ begin
  if exists(select 1 from taskfold_private.reminder_devices where id='fd229de1-c5b4-4f06-a4e1-e6a329310924') then raise exception 'Anonymous retirement created storage'; end if;
end $$;
delete from auth.sessions where id='fd229de1-c5b4-4f06-a4e1-e6a329310911';
do $$ begin
  if exists(select 1 from taskfold_private.reminder_devices where user_id='fd229de1-c5b4-4f06-a4e1-e6a329310901' or session_id='fd229de1-c5b4-4f06-a4e1-e6a329310911') then raise exception 'Deleted session left active address'; end if;
end $$;
set local role authenticated;
set local request.jwt.claim.sub = 'fd229de1-c5b4-4f06-a4e1-e6a329310901';
set local request.jwt.claims = '{"sub":"fd229de1-c5b4-4f06-a4e1-e6a329310901","role":"authenticated","session_id":"fd229de1-c5b4-4f06-a4e1-e6a329310911"}';
do $$ begin
  begin perform public.taskfold_register_reminder_device('fd229de1-c5b4-4f06-a4e1-e6a329310921',repeat('a',64),7,'{}'); raise exception 'Revoked session registered'; exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
