-- Run as one statement batch. Isolated users and all changes roll back.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
 ('f01dcafe-2000-4000-8000-000000000001','taskfold-views-owner@example.invalid','{}'),
 ('f01dcafe-2000-4000-8000-000000000002','taskfold-views-outsider@example.invalid','{}');
select set_config('request.jwt.claim.sub','f01dcafe-2000-4000-8000-000000000001',true);
set local role authenticated;
-- Regress INSERT ... RETURNING visibility, which exercises the native HTTP contract.
insert into public.projects(id,user_id,name) values('f01dcafe-2000-4000-8000-000000000020',auth.uid(),'HTTP-compatible creation') returning id;

insert into public.saved_views(id,name,query_ast) values
 ('f01dcafe-2000-4000-8000-000000000010','Focus','{"version":1,"root":{"op":"predicate","field":"today","value":""}}');
insert into public.favorites(id,order_index) values ('today',0),('view:f01dcafe-2000-4000-8000-000000000010',1);
insert into public.view_preferences(id,sort_by,priority_filter) values ('today','duration',1);
insert into public.view_orders(id,ids) values ('scope:view:f01dcafe-2000-4000-8000-000000000010:group:all','["b","a"]');
update public.saved_views set name='Renamed',layout='board',grouping='priority' where id='f01dcafe-2000-4000-8000-000000000010';
-- Simulate an independent device changing just one setting. Existing fields must survive.
insert into public.view_preferences(user_id,id,include_completed) values(auth.uid(),'today',true)
 on conflict(user_id,id) do update set include_completed=excluded.include_completed;
insert into public.view_orders(user_id,id,ids) values(auth.uid(),'scope:view:f01dcafe-2000-4000-8000-000000000010:group:all','["a","b"]')
 on conflict(user_id,id) do update set ids=excluded.ids;
do $$ declare invalid jsonb; begin
 if not exists(select 1 from public.saved_views where id='f01dcafe-2000-4000-8000-000000000010' and name='Renamed' and layout='board' and grouping='priority') then raise exception 'View update failed'; end if;
 if not exists(select 1 from public.view_preferences where id='today' and sort_by='duration' and priority_filter=1 and include_completed) then raise exception 'Partial settings update erased other fields'; end if;
 if not exists(select 1 from public.favorites where id='view:f01dcafe-2000-4000-8000-000000000010' and order_index=1) then raise exception 'Rename retargeted favorite'; end if;
 if (select ids from public.view_orders where id='scope:view:f01dcafe-2000-4000-8000-000000000010:group:all') <> '["a","b"]'::jsonb then raise exception 'Stable order upsert failed'; end if;
 foreach invalid in array array['{}'::jsonb,'{"version":1}'::jsonb,'{"version":"1","root":{}}'::jsonb,'{"version":2,"root":{}}'::jsonb,'{"version":1,"root":[]}'::jsonb] loop
  begin
   insert into public.saved_views(name,query_ast) values('Invalid',invalid); raise exception 'Invalid query envelope accepted: %',invalid;
  exception when check_violation then null; end;
 end loop;
 begin
  update public.view_orders set ids='[1]' where id='scope:view:f01dcafe-2000-4000-8000-000000000010:group:all'; raise exception 'Numeric order ID accepted';
 exception when check_violation then null; end;
 begin
  update public.view_preferences set sort_by='unknown' where id='today'; raise exception 'Unsupported sort accepted';
 exception when check_violation then null; end;
 begin
  update public.saved_views set user_id='f01dcafe-2000-4000-8000-000000000002' where id='f01dcafe-2000-4000-8000-000000000010'; raise exception 'Ownership transfer accepted';
 exception when others then if sqlerrm <> 'Organization ownership cannot be changed' then raise; end if; end;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-2000-4000-8000-000000000002',true);
do $$ begin
 if exists(select 1 from public.projects where id='f01dcafe-2000-4000-8000-000000000020') then raise exception 'Project ownership visibility leaked'; end if;
 if exists(select 1 from public.saved_views) or exists(select 1 from public.favorites) or exists(select 1 from public.view_preferences) or exists(select 1 from public.view_orders) then raise exception 'Organization data leaked across accounts'; end if;
 begin
  insert into public.favorites(user_id,id) values('f01dcafe-2000-4000-8000-000000000001','foreign'); raise exception 'Foreign favorite accepted';
 exception when insufficient_privilege then null; end;
 update public.saved_views set name='Stolen' where id='f01dcafe-2000-4000-8000-000000000010';
 if found then raise exception 'Foreign view changed'; end if;
end $$;
-- Same stable built-in keys belong independently to each account.
insert into public.favorites(id,order_index) values('today',3);
insert into public.view_preferences(id,sort_by) values('today','title');
insert into public.view_orders(id,ids) values('scope:view:f01dcafe-2000-4000-8000-000000000010:group:all','["different"]');
select set_config('request.jwt.claim.sub','f01dcafe-2000-4000-8000-000000000001',true);
do $$ begin
 if (select sort_by from public.view_preferences where id='today') <> 'duration' or (select order_index from public.favorites where id='today') <> 0 then raise exception 'Composite keys crossed accounts'; end if;
end $$;
reset role;
set local role anon;
do $$ declare t text; begin
 foreach t in array array['saved_views','favorites','view_preferences','view_orders'] loop
  if has_table_privilege(current_user,'public.'||t,'select') or has_table_privilege(current_user,'public.'||t,'insert') then raise exception 'Anonymous privilege on %',t; end if;
 end loop;
end $$;
reset role;
rollback;
