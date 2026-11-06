-- Reserved synthetic users/tasks only. Run as postgres. Always rolls back.
begin;
create temporary table handoff_checks(name text primary key);
grant select,insert on handoff_checks to authenticated,anon;
create function pg_temp.handoff_assert(ok boolean,label text) returns void language plpgsql security invoker as $$begin if not coalesce(ok,false) then raise exception 'Private handoff check failed: %',label; end if; insert into pg_temp.handoff_checks values(label);end$$;
create function pg_temp.handoff_blocked(stmt text) returns boolean language plpgsql security invoker as $$declare blocked boolean:=false;begin begin execute stmt; exception when insufficient_privilege or data_exception or program_limit_exceeded then blocked:=true;end;return blocked;end$$;
insert into auth.users(id,email,raw_user_meta_data) values
 ('f083cafe-8100-4000-8000-000000000001','taskfold-handoff-owner@example.invalid','{}'),
 ('f083cafe-8100-4000-8000-000000000002','taskfold-handoff-member@example.invalid','{}'),
 ('f083cafe-8100-4000-8000-000000000003','taskfold-handoff-outsider@example.invalid','{"owner":true}'),
 ('f083cafe-8100-4000-8000-000000000004','taskfold-handoff-quota@example.invalid','{}');
insert into public.projects(id,user_id,name) values('f083cafe-8200-4000-8000-000000000001','f083cafe-8100-4000-8000-000000000001','Synthetic handoff project');
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000001',true);
insert into public.project_collaborators(id,project_id,invited_email,invited_by) values('f083cafe-8300-4000-8000-000000000001','f083cafe-8200-4000-8000-000000000001','taskfold-handoff-member@example.invalid',auth.uid());
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000002',true);
update public.project_collaborators set status='accepted' where id='f083cafe-8300-4000-8000-000000000001';
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000001',true);
insert into public.tasks(id,user_id,project_id,title,task_generation,completion_version) values
 ('f083cafe-8400-4000-8000-000000000001','f083cafe-8100-4000-8000-000000000001',null,'Synthetic private handoff task','f083cafe-8500-4000-8000-000000000001',0),
 ('f083cafe-8400-4000-8000-000000000002','f083cafe-8100-4000-8000-000000000001','f083cafe-8200-4000-8000-000000000001','Synthetic shared handoff task','f083cafe-8500-4000-8000-000000000002',0);
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000004',true);
insert into public.tasks(id,user_id,project_id,title,task_generation,completion_version) values
 ('f083cafe-8400-4000-8000-000000000004','f083cafe-8100-4000-8000-000000000004',null,'Synthetic quota task','f083cafe-8500-4000-8000-000000000004',0);
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000001',true);
create temporary table handoff_baseline as select id,to_jsonb(t) as value from public.tasks t where id in ('f083cafe-8400-4000-8000-000000000001','f083cafe-8400-4000-8000-000000000002');
create function pg_temp.handoff_request(_id uuid,_shared boolean default false) returns jsonb language sql stable as $$select jsonb_build_object('version',1,'id',_id,'task_id',case when _shared then 'f083cafe-8400-4000-8000-000000000002' else 'f083cafe-8400-4000-8000-000000000001' end,'task_generation',case when _shared then 'f083cafe-8500-4000-8000-000000000002' else 'f083cafe-8500-4000-8000-000000000001' end,'completion_version',0,'authored_at_ms',floor(extract(epoch from now())*1000)::bigint,'place_name','Synthetic private workshop','latitude_e6',55676098,'longitude_e6',12568337,'radius_m',250,'transition','arrive','repeats',false)$$;
select pg_temp.handoff_assert(not has_table_privilege('authenticated','taskfold_private.location_handoffs','select') and not has_table_privilege('authenticated','taskfold_private.location_handoffs','insert') and not has_function_privilege('anon','public.taskfold_location_handoff_list(uuid)','execute') and not has_function_privilege('authenticated','taskfold_private.prune_location_handoffs()','execute') and (select relrowsecurity from pg_class where oid='taskfold_private.location_handoffs'::regclass),'private table grants, RLS and maintenance isolation');
select pg_temp.handoff_assert(not exists(select 1 from pg_publication_tables where schemaname='taskfold_private' and tablename='location_handoffs'),'private geometry is not published to Realtime');
set local role anon;
select pg_temp.handoff_assert(pg_temp.handoff_blocked('select public.taskfold_location_handoff_list()'),'anonymous RPC denied');
reset role;
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000001',true);
set local role authenticated;
do $$declare request jsonb:=pg_temp.handoff_request('f083cafe-8600-4000-8000-000000000001'); first jsonb; second jsonb; bad jsonb;begin
 first:=public.taskfold_location_handoff_put(request);
 second:=public.taskfold_location_handoff_put(request||'{"version":1.0,"completion_version":0.0,"radius_m":250.0}'::jsonb);
 perform pg_temp.handoff_assert(first=second and first#>>'{items,0,state}'='pending' and first#>>'{items,0,payload,place_name}'='Synthetic private workshop','put is idempotent, including equivalent integral numeric representations');
 perform pg_temp.handoff_assert(pg_temp.handoff_blocked(format('select public.taskfold_location_handoff_put(%L::jsonb)',request||'{"radius_m":500}'::jsonb)),'changed-content retry cannot extend or replace a draft');
 for bad in select value from jsonb_array_elements('[{"version":2},{"radius_m":99},{"latitude_e6":90000001},{"completion_version":-1},{"longitude_e6":1.5},{"repeats":"true"},{"transition":"enter"},{"place_name":" "},{"extra":"no"},{"task_id":"bad"}]') loop
  if not pg_temp.handoff_blocked(format('select public.taskfold_location_handoff_put(%L::jsonb)',request||bad)) then raise exception 'Malformed draft accepted: %',bad;end if;
 end loop;
 perform pg_temp.handoff_assert(true,'strict version, fields, numeric, name, transition and UUID validation');
 perform pg_temp.handoff_assert(pg_temp.handoff_blocked(format('select public.taskfold_location_handoff_put(%L::jsonb)',request||jsonb_build_object('id',gen_random_uuid(),'authored_at_ms',0))),'old authored time cannot resurrect a pruned draft');
 perform pg_temp.handoff_assert(pg_temp.handoff_blocked('select * from taskfold_private.location_handoffs'),'authenticated direct table read denied');
end $$;
-- A separate account with access to the shared task still cannot see/claim this owner draft.
select public.taskfold_location_handoff_put(pg_temp.handoff_request('f083cafe-8600-4000-8000-000000000002',true));
reset role;
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000002',true);
set local role authenticated;
select pg_temp.handoff_assert(jsonb_array_length(public.taskfold_location_handoff_list()->'items')=0 and pg_temp.handoff_blocked($q$select public.taskfold_location_handoff_claim('f083cafe-8600-4000-8000-000000000002','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000001')$q$),'accepted collaborator cannot read or claim another account handoff');
select public.taskfold_location_handoff_put(pg_temp.handoff_request('f083cafe-8600-4000-8000-000000000002',true));
select pg_temp.handoff_assert(jsonb_array_length(public.taskfold_location_handoff_list()->'items')=1,'same draft UUID is independently owned per account');
reset role;
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000003',true);
set local role authenticated;
select pg_temp.handoff_assert(jsonb_array_length(public.taskfold_location_handoff_list()->'items')=0 and pg_temp.handoff_blocked(format('select public.taskfold_location_handoff_put(%L::jsonb)',pg_temp.handoff_request('f083cafe-8600-4000-8000-000000000003',true))),'outsider and user-editable metadata cannot authorize task handoff');
reset role;
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000001',true);
set local role authenticated;
do $$declare a jsonb;b jsonb;begin
 a:=public.taskfold_location_handoff_claim('f083cafe-8600-4000-8000-000000000001','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000001');
 b:=public.taskfold_location_handoff_claim('f083cafe-8600-4000-8000-000000000001','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000001');
 perform pg_temp.handoff_assert(a=b and a#>>'{items,0,state}'='claimed','same device and nonce recover a lost claim response');
 perform pg_temp.handoff_assert(pg_temp.handoff_blocked($q$select public.taskfold_location_handoff_claim('f083cafe-8600-4000-8000-000000000001','f083cafe-8700-4000-8000-000000000002','f083cafe-8800-4000-8000-000000000002')$q$) and pg_temp.handoff_blocked($q$select public.taskfold_location_handoff_discard('f083cafe-8600-4000-8000-000000000001')$q$),'another device cannot retarget a claim and sender cannot discard an active device review');
 a:=public.taskfold_location_handoff_list('f083cafe-8700-4000-8000-000000000002');
 perform pg_temp.handoff_assert((select item->'payload'='null'::jsonb from jsonb_array_elements(a->'items') item where item->>'id'='f083cafe-8600-4000-8000-000000000001') and position('f083cafe-8800-4000-8000-000000000001' in a::text)=0,'other-device list redacts claimed geometry and never exposes claim nonce');
 a:=public.taskfold_location_handoff_finish('f083cafe-8600-4000-8000-000000000001','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000001');
 b:=public.taskfold_location_handoff_claim('f083cafe-8600-4000-8000-000000000001','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000001');
 perform pg_temp.handoff_assert(a=b and a#>>'{items,0,state}'='imported' and a#>'{items,0,payload}'='null'::jsonb,'finish purges geometry and replay never rearms an imported draft');
 perform pg_temp.handoff_assert(pg_temp.handoff_blocked($q$select public.taskfold_location_handoff_finish('f083cafe-8600-4000-8000-000000000001','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000099')$q$),'finish cannot substitute a nonce');
end $$;
select public.taskfold_location_handoff_put(pg_temp.handoff_request('f083cafe-8600-4000-8000-000000000004'));
select public.taskfold_location_handoff_discard('f083cafe-8600-4000-8000-000000000004');
select pg_temp.handoff_assert(public.taskfold_location_handoff_put(pg_temp.handoff_request('f083cafe-8600-4000-8000-000000000004'))#>>'{items,0,state}'='discarded' and pg_temp.handoff_blocked($q$select public.taskfold_location_handoff_claim('f083cafe-8600-4000-8000-000000000004','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000004')$q$),'discarded draft cannot be resurrected by put or claim');
select public.taskfold_location_handoff_put(pg_temp.handoff_request('f083cafe-8600-4000-8000-000000000005'));
select public.taskfold_location_handoff_claim('f083cafe-8600-4000-8000-000000000005','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000005');
select pg_temp.handoff_assert(public.taskfold_location_handoff_abandon('f083cafe-8600-4000-8000-000000000005','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000005')#>>'{items,0,state}'='discarded','own device may abandon a claim and clear geometry');
reset role;
create temporary table handoff_golden(name text primary key,body jsonb);
grant select,insert on handoff_golden to authenticated;
set local role authenticated;
insert into handoff_golden values('pending',public.taskfold_location_handoff_put(pg_temp.handoff_request('f083cafe-8600-4000-8000-000000000006')));
insert into handoff_golden values('claimed',public.taskfold_location_handoff_claim('f083cafe-8600-4000-8000-000000000006','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000006'));
insert into handoff_golden values('other-device',public.taskfold_location_handoff_list('f083cafe-8700-4000-8000-000000000002'));
insert into handoff_golden values('imported',public.taskfold_location_handoff_finish('f083cafe-8600-4000-8000-000000000006','f083cafe-8700-4000-8000-000000000001','f083cafe-8800-4000-8000-000000000006'));
reset role;
select pg_temp.handoff_assert(not exists(select 1 from public.tasks t join handoff_baseline b using(id) where to_jsonb(t)<>b.value),'handoff lifecycle never mutates shared or private task rows');
-- Revocation and root-incarnation changes redact data and refuse fresh claims.
update public.tasks set completed=true,completion_version=completion_version+1 where id='f083cafe-8400-4000-8000-000000000002';
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000002',true);
set local role authenticated;
select pg_temp.handoff_assert(public.taskfold_location_handoff_list()#>'{items,0,payload}'='null'::jsonb and pg_temp.handoff_blocked($q$select public.taskfold_location_handoff_claim('f083cafe-8600-4000-8000-000000000002','f083cafe-8700-4000-8000-000000000002','f083cafe-8800-4000-8000-000000000002')$q$),'completed task cannot be reviewed or reveal geometry');
reset role;
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000001',true);
update public.tasks set completed=false,completion_version=completion_version+1 where id='f083cafe-8400-4000-8000-000000000002';
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000002',true);
set local role authenticated;
select pg_temp.handoff_assert(public.taskfold_location_handoff_list()#>'{items,0,payload}'='null'::jsonb,'completion reversal cannot revive old draft authority');
select pg_temp.handoff_assert(pg_temp.handoff_blocked(format('select public.taskfold_location_handoff_put(%L::jsonb)',pg_temp.handoff_request('f083cafe-8600-4000-8000-000000000008',true)||jsonb_build_object('task_generation','f083cafe-8500-4000-8000-000000000099','completion_version',(select completion_version from public.tasks where id='f083cafe-8400-4000-8000-000000000002')))),'stale task generation refuses a new draft');
select public.taskfold_location_handoff_put(pg_temp.handoff_request('f083cafe-8600-4000-8000-000000000007',true)||jsonb_build_object('completion_version',(select completion_version from public.tasks where id='f083cafe-8400-4000-8000-000000000002')));
reset role;
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000001',true);
delete from public.project_collaborators where id='f083cafe-8300-4000-8000-000000000001';
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000002',true);
set local role authenticated;
select pg_temp.handoff_assert((select item->'payload'='null'::jsonb from jsonb_array_elements(public.taskfold_location_handoff_list()->'items') item where item->>'id'='f083cafe-8600-4000-8000-000000000007'),'lost project membership redacts a fresh private draft');
reset role;
-- Advance only synthetic rows' timestamps to exercise scheduled retention.
update taskfold_private.location_handoffs set created_at=now()-interval '8 days',expires_at=now()-interval '1 day' where user_id='f083cafe-8100-4000-8000-000000000001' and state='pending';
select taskfold_private.prune_location_handoffs();
select pg_temp.handoff_assert(not exists(select 1 from taskfold_private.location_handoffs where expires_at<=now() and payload is not null),'expiry clears coordinates for inactive owners');
-- Account quota and permanent claim/tombstone safety are serialized by owner lock.
select set_config('request.jwt.claim.sub','f083cafe-8100-4000-8000-000000000004',true);
set local role authenticated;
do $$declare request jsonb; i integer;begin
 for i in 1..32 loop
  request:=pg_temp.handoff_request(('f083cafe-8900-4000-8000-'||lpad(i::text,12,'0'))::uuid)||'{"task_id":"f083cafe-8400-4000-8000-000000000004","task_generation":"f083cafe-8500-4000-8000-000000000004"}'::jsonb;
  perform public.taskfold_location_handoff_put(request);
 end loop;
 request:=request||'{"id":"f083cafe-8900-4000-8000-000000000033"}'::jsonb;
 perform pg_temp.handoff_assert(pg_temp.handoff_blocked(format('select public.taskfold_location_handoff_put(%L::jsonb)',request)),'32 active private drafts bound enforced');
 perform public.taskfold_location_handoff_discard('f083cafe-8900-4000-8000-000000000001');
 perform public.taskfold_location_handoff_put(request);
 perform public.taskfold_location_handoff_discard('f083cafe-8900-4000-8000-000000000033');
 for i in 2..32 loop perform public.taskfold_location_handoff_discard(('f083cafe-8900-4000-8000-'||lpad(i::text,12,'0'))::uuid);end loop;
 for i in 34..256 loop
  request:=request||jsonb_build_object('id','f083cafe-8900-4000-8000-'||lpad(i::text,12,'0'));
  perform public.taskfold_location_handoff_put(request);
  perform public.taskfold_location_handoff_discard((request->>'id')::uuid);
 end loop;
 request:=request||'{"id":"f083cafe-8900-4000-8000-000000000257"}'::jsonb;
 perform pg_temp.handoff_assert(pg_temp.handoff_blocked(format('select public.taskfold_location_handoff_put(%L::jsonb)',request)),'256 retained metadata bound enforced without forgetting tombstones');
end $$;
reset role;
update taskfold_private.location_handoffs set created_at=now()-interval '31 days',expires_at=now()-interval '24 days' where user_id='f083cafe-8100-4000-8000-000000000004';
select taskfold_private.prune_location_handoffs();
select pg_temp.handoff_assert(not exists(select 1 from taskfold_private.location_handoffs where user_id='f083cafe-8100-4000-8000-000000000004') and exists(select 1 from cron.job where jobname='taskfold-location-handoff-retention' and schedule='17 * * * *' and command='select taskfold_private.prune_location_handoffs()'),'30-day metadata retention and configured hourly geometry cleanup');
delete from auth.users where id='f083cafe-8100-4000-8000-000000000002';
select pg_temp.handoff_assert(not exists(select 1 from taskfold_private.location_handoffs where user_id='f083cafe-8100-4000-8000-000000000002'),'account deletion removes private drafts');
select name as handoff_golden_name,body as handoff_golden from handoff_golden order by name;
select jsonb_build_object('private_handoff_fixture_passed',true,'checks',(select jsonb_agg(name order by name) from handoff_checks),'actual_check_count',(select count(*) from handoff_checks));
rollback;
