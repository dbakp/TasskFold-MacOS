-- Run with the Supabase SQL tool as a disposable, rolled-back fixture.
-- No application schema or real workspace records are modified.
begin;
insert into auth.users(id) values ('715ab0d9-ea4c-4fe4-b4a8-eaac6e25be92'), ('8fb75652-628d-477c-ac9e-b6a631b927cb');
set local role authenticated;
set local request.jwt.claim.sub = '715ab0d9-ea4c-4fe4-b4a8-eaac6e25be92';
set local request.jwt.claims = '{"sub":"715ab0d9-ea4c-4fe4-b4a8-eaac6e25be92","role":"authenticated"}';
insert into public.view_orders(user_id,id,ids) values
('715ab0d9-ea4c-4fe4-b4a8-eaac6e25be92','widget-note:fixture-pinned-a','["fixture-pinned-a"]'),
('715ab0d9-ea4c-4fe4-b4a8-eaac6e25be92','widget-note:fixture-pinned-b','["fixture-pinned-b"]')
on conflict(user_id,id) do update set ids=excluded.ids;
do $$ begin
if (select count(*) from public.view_orders where id in ('widget-note:fixture-pinned-a','widget-note:fixture-pinned-b')) <> 2 then raise exception 'Independent owner pins missing'; end if;
end $$;
set local request.jwt.claim.sub = '8fb75652-628d-477c-ac9e-b6a631b927cb';
set local request.jwt.claims = '{"sub":"8fb75652-628d-477c-ac9e-b6a631b927cb","role":"authenticated"}';
do $$ begin
if exists(select 1 from public.view_orders where id in ('widget-note:fixture-pinned-a','widget-note:fixture-pinned-b')) then raise exception 'Foreign pin visible'; end if;
begin
insert into public.view_orders(user_id,id,ids) values ('715ab0d9-ea4c-4fe4-b4a8-eaac6e25be92','widget-note:fixture-pinned-c','["fixture-pinned-c"]');
raise exception 'Foreign insert accepted';
exception when insufficient_privilege then null;
end;
end $$;
insert into public.view_orders(user_id,id,ids) values ('8fb75652-628d-477c-ac9e-b6a631b927cb','widget-note:fixture-pinned-a','["fixture-pinned-a"]');
delete from public.view_orders where user_id='715ab0d9-ea4c-4fe4-b4a8-eaac6e25be92' and id='widget-note:fixture-pinned-a';
set local request.jwt.claim.sub = '715ab0d9-ea4c-4fe4-b4a8-eaac6e25be92';
set local request.jwt.claims = '{"sub":"715ab0d9-ea4c-4fe4-b4a8-eaac6e25be92","role":"authenticated"}';
do $$ begin
if (select count(*) from public.view_orders where id in ('widget-note:fixture-pinned-a','widget-note:fixture-pinned-b')) <> 2 then raise exception 'Foreign deletion changed owner pins'; end if;
end $$;
delete from public.view_orders where id='widget-note:fixture-pinned-a';
do $$ begin
if exists(select 1 from public.view_orders where id='widget-note:fixture-pinned-a') or not exists(select 1 from public.view_orders where id='widget-note:fixture-pinned-b') then raise exception 'Unpin changed independent pin'; end if;
end $$;
select 'Independent pins, owner upsert/delete and outsider isolation passed; transaction rolled back' as result;
rollback;
