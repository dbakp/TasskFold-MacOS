begin;
insert into auth.users(id) values('f091cafe-0000-4000-8000-000000000001'),('f091cafe-0000-4000-8000-000000000002');
insert into auth.sessions(id,user_id) values('f091cafe-0000-4000-8000-000000000011','f091cafe-0000-4000-8000-000000000001'),('f091cafe-0000-4000-8000-000000000012','f091cafe-0000-4000-8000-000000000002');
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$begin if ok is distinct from true then raise exception 'Assertion failed: %',label;end if;end$$;
create function pg_temp.body(_n integer default 21) returns jsonb language sql as $$ select jsonb_build_object('id','f091cafe-0000-4000-8000-'||lpad(_n::text,12,'0'),'name','Build script','token_hash',lpad(_n::text,64,'0'),'scopes',jsonb_build_array('tasks:create','tasks:read'),'ttl_days',30) $$;
do $$declare role_name text;begin
 foreach role_name in array array['anon','authenticated'] loop
  perform pg_temp.require(not has_table_privilege(role_name,'taskfold_private.automation_keys','select'),'client key read revoked');
  perform pg_temp.require(not has_table_privilege(role_name,'taskfold_private.automation_keys','insert'),'client key writes revoked');
  perform pg_temp.require(not has_table_privilege(role_name,'taskfold_private.automation_account_usage','select'),'usage private');
  perform pg_temp.require(not has_function_privilege(role_name,'public.taskfold_automation_keys(uuid,uuid,text,jsonb)','execute'),'management RPC private');
  perform pg_temp.require(not has_function_privilege(role_name,'taskfold_private.automation_authorize(uuid,text,text)','execute'),'no standalone authorization access');
 end loop;
 perform pg_temp.require(not has_function_privilege('service_role','taskfold_private.automation_authorize(uuid,text,text)','execute'),'helper not exposed to service gateway');
end$$;
-- Genuine service role can only use its scoped management wrapper.
set local role service_role;
do $$declare reply jsonb;begin
 reply=public.taskfold_automation_keys('f091cafe-0000-4000-8000-000000000001','f091cafe-0000-4000-8000-000000000011','list','{}');
 if reply->'keys'<>'[]'::jsonb then raise exception 'Service list unavailable';end if;
 begin
  perform public.taskfold_automation_keys('f091cafe-0000-4000-8000-000000000001','f091cafe-0000-4000-8000-000000000012','list','{}');
  raise exception 'Foreign session accepted';
 exception when invalid_authorization_specification then null;end;
end$$;
reset role;
do $$declare a uuid='f091cafe-0000-4000-8000-000000000001';s uuid='f091cafe-0000-4000-8000-000000000011';b jsonb;reply jsonb;first_reply jsonb;again jsonb;key_id uuid='f091cafe-0000-4000-8000-000000000021';i integer; cursor_id text; seen uuid[]:=array[]::uuid[]; item jsonb;
begin
 foreach b in array array['null'::jsonb,'[]'::jsonb,pg_temp.body()||'{"admin":true}',pg_temp.body()||'{"name":" "}',pg_temp.body()||jsonb_build_object('name',E'bad\nname'),pg_temp.body()||'{"scopes":[]}',pg_temp.body()||'{"scopes":["admin"]}',pg_temp.body()||'{"scopes":["tasks:create","tasks:create"]}',pg_temp.body()||'{"scopes":[null]}',pg_temp.body()||'{"ttl_days":"30"}',pg_temp.body()||'{"ttl_days":30.5}',pg_temp.body()||'{"token_hash":"raw-token"}'] loop
  begin
   perform public.taskfold_automation_keys(a,s,'create',b);raise exception 'Invalid body accepted';
  exception when invalid_parameter_value then null;end;
 end loop;
 perform pg_temp.require((select count(*)=0 from taskfold_private.automation_keys),'invalid creates have no side effects');
 first_reply=public.taskfold_automation_keys(a,s,'create',pg_temp.body());
 again=public.taskfold_automation_keys(a,s,'create',pg_temp.body());
 perform pg_temp.require(first_reply=again,'same command exact receipt without renewed expiry');
 perform pg_temp.require(not (first_reply->'key') ?| array['token_hash','secret','user_id','window_requests'],'metadata excludes private fields');
 perform pg_temp.require(first_reply->'key'->>'prefix'='tfk_v1_f091cafe','safe display prefix');
 begin
  perform public.taskfold_automation_keys(a,s,'create',pg_temp.body()||'{"name":"Changed request"}');raise exception 'Changed retry accepted';
 exception when unique_violation then null;end;
 begin
  perform public.taskfold_automation_keys('f091cafe-0000-4000-8000-000000000002','f091cafe-0000-4000-8000-000000000012','revoke',jsonb_build_object('id',key_id));raise exception 'Foreign revoke accepted';
 exception when insufficient_privilege then null;end;
 perform pg_temp.require(taskfold_private.automation_authorize(key_id,lpad('21',64,'0'),'tasks:create')=a,'correct scope authorizes');
 begin
  perform taskfold_private.automation_authorize(key_id,lpad('21',64,'0'),'tasks:delete');raise exception 'Unscoped operation accepted';
 exception when insufficient_privilege then null;end;
 begin
  perform taskfold_private.automation_authorize(key_id,lpad('99',64,'0'),'tasks:create');raise exception 'Wrong secret accepted';
 exception when invalid_authorization_specification then null;end;
 for i in 2..60 loop perform taskfold_private.automation_authorize(key_id,lpad('21',64,'0'),'tasks:read');end loop;
 begin
  perform taskfold_private.automation_authorize(key_id,lpad('21',64,'0'),'tasks:read');raise exception 'Minute quota exceeded';
 exception when sqlstate 'PT429' then null;end;
 perform pg_temp.require((select day_requests=60 and window_requests=60 from taskfold_private.automation_keys where id=key_id),'denied quota has no partial counters');
 update taskfold_private.automation_keys set window_started_at=clock_timestamp()-interval '2 minutes',day_requests=1000 where id=key_id;
 begin
  perform taskfold_private.automation_authorize(key_id,lpad('21',64,'0'),'tasks:read');raise exception 'Daily key quota exceeded';
 exception when sqlstate 'PT429' then null;end;
 update taskfold_private.automation_keys set day_requests=0,window_requests=0 where id=key_id;
 update taskfold_private.automation_account_usage set requests=2000 where user_id=a;
 begin
  perform taskfold_private.automation_authorize(key_id,lpad('21',64,'0'),'tasks:read');raise exception 'Account quota exceeded';
 exception when sqlstate 'PT429' then null;end;
 update taskfold_private.automation_account_usage set requests=0 where user_id=a;
 update taskfold_private.automation_keys set usage_day=current_date-1,day_requests=1000,window_started_at=clock_timestamp()-interval '2 minutes' where id=key_id;
 perform taskfold_private.automation_authorize(key_id,lpad('21',64,'0'),'tasks:read');
 perform pg_temp.require((select day_requests=1 and window_requests=1 from taskfold_private.automation_keys where id=key_id),'expired quota windows reset');
 reply=public.taskfold_automation_keys(a,s,'revoke',jsonb_build_object('id',key_id));
 again=public.taskfold_automation_keys(a,s,'revoke',jsonb_build_object('id',key_id));
 perform pg_temp.require(reply=again and reply->'key'->>'revoked_at' is not null,'revocation immutable');
 again=public.taskfold_automation_keys(a,s,'create',pg_temp.body());
 perform pg_temp.require(again=reply,'old create retry cannot un-revoke');
 begin
  perform taskfold_private.automation_authorize(key_id,lpad('21',64,'0'),'tasks:read');raise exception 'Revoked key accepted';
 exception when invalid_authorization_specification then null;end;
 -- Expiry, current session, ban and pending removal are independent barriers.
 perform public.taskfold_automation_keys(a,s,'create',pg_temp.body(22));
 update taskfold_private.automation_keys set expires_at=clock_timestamp()-interval '1 second' where id=(pg_temp.body(22)->>'id')::uuid;
 begin
  perform taskfold_private.automation_authorize((pg_temp.body(22)->>'id')::uuid,lpad('22',64,'0'),'tasks:read');raise exception 'Expired key accepted';
 exception when invalid_authorization_specification then null;end;
 perform public.taskfold_automation_keys(a,s,'create',pg_temp.body(23));
 update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id=s;
 begin perform public.taskfold_automation_keys(a,s,'list','{}');raise exception 'Expired session accepted';exception when invalid_authorization_specification then null;end;
 perform pg_temp.require(taskfold_private.automation_authorize((pg_temp.body(23)->>'id')::uuid,lpad('23',64,'0'),'tasks:read')=a,'API key independent of native sign-out');
 update auth.sessions set not_after=null where id=s;
 update auth.users set banned_until=clock_timestamp()+interval '1 hour' where id=a;
 begin perform public.taskfold_automation_keys(a,s,'list','{}');raise exception 'Banned user accepted';exception when invalid_authorization_specification then null;end;
 begin perform taskfold_private.automation_authorize((pg_temp.body(23)->>'id')::uuid,lpad('23',64,'0'),'tasks:read');raise exception 'Banned API key accepted';exception when invalid_authorization_specification then null;end;
 update auth.users set banned_until=null where id=a;
 insert into taskfold_private.account_removal_receipts(token_hash,account_id) values(repeat('a',64),a);
 begin perform public.taskfold_automation_keys(a,s,'list','{}');raise exception 'Pending removal accepted';exception when invalid_authorization_specification then null;end;
 begin perform taskfold_private.automation_authorize((pg_temp.body(23)->>'id')::uuid,lpad('23',64,'0'),'tasks:read');raise exception 'Pending-removal API key accepted';exception when invalid_authorization_specification then null;end;
 perform pg_temp.require((select revoked_at is not null from taskfold_private.automation_keys where id=(pg_temp.body(23)->>'id')::uuid),'begin removal revokes existing keys');
 delete from taskfold_private.account_removal_receipts where account_id=a;
 begin perform taskfold_private.automation_authorize((pg_temp.body(23)->>'id')::uuid,lpad('23',64,'0'),'tasks:read');raise exception 'Pruned removal receipt resurrected key';exception when invalid_authorization_specification then null;end;
 for i in 23..30 loop perform public.taskfold_automation_keys(a,s,'create',pg_temp.body(i));end loop;
 begin perform public.taskfold_automation_keys(a,s,'create',pg_temp.body(31));raise exception 'Issuance daily cap exceeded';exception when sqlstate 'PT429' then null;end;
 -- Simulate older active keys; current active-key cap cannot race the mutex.
 update taskfold_private.automation_keys set created_at=clock_timestamp()-interval '2 days' where user_id=a;
 for i in 31..40 loop perform public.taskfold_automation_keys(a,s,'create',pg_temp.body(i));end loop;
 update taskfold_private.automation_keys set created_at=clock_timestamp()-interval '2 days' where user_id=a;
 for i in 41..43 loop perform public.taskfold_automation_keys(a,s,'create',pg_temp.body(i));end loop;
 begin perform public.taskfold_automation_keys(a,s,'create',pg_temp.body(44));raise exception 'Active key cap exceeded';exception when sqlstate 'PT429' then null;end;
 perform pg_temp.require(jsonb_array_length(public.taskfold_automation_keys('f091cafe-0000-4000-8000-000000000002','f091cafe-0000-4000-8000-000000000012','list','{}')->'keys')=0,'foreign metadata never listed');
 perform pg_temp.require(jsonb_array_length(public.taskfold_automation_keys(a,s,'list','{}')->'keys')=20,'default list excludes revoked/expired');
 loop
  reply=public.taskfold_automation_keys(a,s,'list',jsonb_build_object('limit',3,'include_inactive',true)||case when cursor_id is null then '{}'::jsonb else jsonb_build_object('cursor',cursor_id) end);
  perform pg_temp.require(jsonb_array_length(reply->'keys')<=3,'bounded list page');
  for item in select * from jsonb_array_elements(reply->'keys') loop
   perform pg_temp.require(not (item->>'id')::uuid=any(seen),'page repeats a key');seen=array_append(seen,(item->>'id')::uuid);
  end loop;
  cursor_id=reply->>'next_cursor';exit when cursor_id is null;
 end loop;
 perform pg_temp.require(cardinality(seen)=23,'complete inactive pagination');
 begin perform public.taskfold_automation_keys('f091cafe-0000-4000-8000-000000000002','f091cafe-0000-4000-8000-000000000012','list',jsonb_build_object('cursor',key_id));raise exception 'Foreign cursor accepted';exception when insufficient_privilege then null;end;
 delete from auth.users where id=a;
 perform pg_temp.require(not exists(select 1 from taskfold_private.automation_keys where user_id=a),'account deletion clears hashes and metadata');
 perform pg_temp.require(not exists(select 1 from taskfold_private.automation_account_usage where user_id=a),'account deletion clears usage');
end$$;
rollback;
