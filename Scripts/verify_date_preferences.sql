-- Disposable owner/foreign/anonymous fixture: all rows roll back.
begin;
insert into auth.users(id) values ('640b1c8f-e955-4237-9e00-f3429ea985a3'),('e91dc3e0-f11f-4e17-a736-b935b03286a6');
set local role authenticated;
set local request.jwt.claim.sub = '640b1c8f-e955-4237-9e00-f3429ea985a3';
set local request.jwt.claims = '{"sub":"640b1c8f-e955-4237-9e00-f3429ea985a3","role":"authenticated"}';
insert into public.view_preferences(user_id,id,date_preferences) values ('640b1c8f-e955-4237-9e00-f3429ea985a3','dates','{"version":1,"next_week":6,"weekend":1,"future_hint":"keep"}');
do $$ declare candidate jsonb; begin
 if (select date_preferences->>'next_week' from public.view_preferences where id='dates') <> '6' then raise exception 'Owner preference missing'; end if;
 foreach candidate in array array['{"version":2}'::jsonb,'{"version":1,"next_week":0,"weekend":7}'::jsonb,'{"version":1,"next_week":2,"weekend":8}'::jsonb,'{"version":1,"next_week":2.5,"weekend":7}'::jsonb,'{"version":1,"next_week":"2","weekend":7}'::jsonb,'{"version":1,"next_week":2}'::jsonb] loop
  begin
   update public.view_preferences set date_preferences=candidate where id='dates';
   raise exception 'Invalid preference accepted: %',candidate;
  exception when check_violation then null; end;
 end loop;
 update public.view_preferences set layout='board' where id='dates';
 if (select date_preferences->>'future_hint' from public.view_preferences where id='dates') <> 'keep' then raise exception 'Legacy update lost preferences'; end if;
end $$;
set local request.jwt.claim.sub = 'e91dc3e0-f11f-4e17-a736-b935b03286a6';
set local request.jwt.claims = '{"sub":"e91dc3e0-f11f-4e17-a736-b935b03286a6","role":"authenticated"}';
do $$ begin
 if exists(select 1 from public.view_preferences where user_id='640b1c8f-e955-4237-9e00-f3429ea985a3') then raise exception 'Foreign preference visible'; end if;
 begin
  insert into public.view_preferences(user_id,id,date_preferences) values ('640b1c8f-e955-4237-9e00-f3429ea985a3','foreign','{"version":1,"next_week":2,"weekend":7}');
  raise exception 'Foreign insert accepted';
 exception when insufficient_privilege then null; end;
 update public.view_preferences set date_preferences=null where user_id='640b1c8f-e955-4237-9e00-f3429ea985a3';
 delete from public.view_preferences where user_id='640b1c8f-e955-4237-9e00-f3429ea985a3';
end $$;
insert into public.view_preferences(user_id,id,date_preferences) values ('e91dc3e0-f11f-4e17-a736-b935b03286a6','dates','{"version":1,"next_week":2,"weekend":7}');
set local request.jwt.claim.sub = '640b1c8f-e955-4237-9e00-f3429ea985a3';
set local request.jwt.claims = '{"sub":"640b1c8f-e955-4237-9e00-f3429ea985a3","role":"authenticated"}';
do $$ begin
 if (select date_preferences->>'next_week' from public.view_preferences where id='dates') <> '6' then raise exception 'Foreign update changed owner'; end if;
end $$;
reset role;
set local role anon;
set local request.jwt.claim.sub = '';
set local request.jwt.claims = '{"role":"anon"}';
do $$ begin
 begin
  perform 1 from public.view_preferences where id='dates';
  raise exception 'Anonymous read allowed';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
select count(*) as remaining_fixture_users from auth.users where id in ('640b1c8f-e955-4237-9e00-f3429ea985a3','e91dc3e0-f11f-4e17-a736-b935b03286a6');
