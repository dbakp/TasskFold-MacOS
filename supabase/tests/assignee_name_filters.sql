-- Disposable actual-role persistence/RLS fixture. JWT claims simulate the SQL
-- authorization context; this is not a real native sign-in or HTTP transport test.
begin;
insert into auth.users(id, email, aud, role, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('f0736000-0000-4000-8000-000000000001', 'assignee-pattern-a@taskfold-fixture.invalid', 'authenticated', 'authenticated', '{}', '{}', now(), now()),
       ('f0736000-0000-4000-8000-000000000002', 'assignee-pattern-b@taskfold-fixture.invalid', 'authenticated', 'authenticated', '{}', '{}', now(), now());
set local role authenticated;
select set_config('request.jwt.claim.sub', 'f0736000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"f0736000-0000-4000-8000-000000000001","role":"authenticated"}', true);
insert into public.saved_views(id,user_id,name,query_ast)
values ('f0736000-0000-4000-8000-000000000011','f0736000-0000-4000-8000-000000000001','Assigned name filters',
'{"version":1,"root":{"op":"sections","children":[{"op":"predicate","field":"assignee_name","value":"M* Smith"},{"op":"predicate","field":"assignee","value":"22222222-2222-4222-8222-222222222222"},{"op":"not","child":{"op":"predicate","field":"assignee_name","value":"*Smith"}}]}}');
do $$
begin
 if not exists(select 1 from public.saved_views where id='f0736000-0000-4000-8000-000000000011' and query_ast->'root'->'children'->0->>'value'='M* Smith' and query_ast->'root'->'children'->1->>'field'='assignee' and query_ast->'root'->'children'->1->>'value'='22222222-2222-4222-8222-222222222222' and query_ast->'root'->'children'->2->'child'->>'field'='assignee_name') then raise exception 'Owner assignment document lost'; end if;
 begin
  insert into public.saved_views(id,user_id,name,query_ast) values('f0736000-0000-4000-8000-000000000012','f0736000-0000-4000-8000-000000000002','Foreign owner','{"version":1,"root":{"op":"predicate","field":"assignee_name","value":"*"}}');
  raise exception 'Foreign insert allowed';
 exception when insufficient_privilege then null; end;
end $$;
update public.saved_views set name='Renamed assigned name view' where id='f0736000-0000-4000-8000-000000000011';
select set_config('request.jwt.claim.sub', 'f0736000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"f0736000-0000-4000-8000-000000000002","role":"authenticated"}', true);
do $$
declare changed integer;
begin
 if exists(select 1 from public.saved_views where id='f0736000-0000-4000-8000-000000000011') then raise exception 'Foreign read allowed'; end if;
 update public.saved_views set name='Foreign rewrite' where id='f0736000-0000-4000-8000-000000000011'; get diagnostics changed=row_count;
 if changed<>0 then raise exception 'Foreign update allowed'; end if;
 delete from public.saved_views where id='f0736000-0000-4000-8000-000000000011'; get diagnostics changed=row_count;
 if changed<>0 then raise exception 'Foreign delete allowed'; end if;
end $$;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{}', true);
do $$
declare changed integer;
begin
 begin
  if exists(select 1 from public.saved_views where id='f0736000-0000-4000-8000-000000000011') then raise exception 'Anon read allowed'; end if;
 exception when insufficient_privilege then null; end;
 begin
  insert into public.saved_views(id,user_id,name,query_ast) values('f0736000-0000-4000-8000-000000000013','f0736000-0000-4000-8000-000000000001','Anonymous','{"version":1,"root":{"op":"predicate","field":"assignee_name","value":"*"}}');
  raise exception 'Anon insert allowed';
 exception when insufficient_privilege then null; end;
 begin
  update public.saved_views set name='Anonymous rewrite' where id='f0736000-0000-4000-8000-000000000011'; get diagnostics changed=row_count;
  if changed<>0 then raise exception 'Anon update allowed'; end if;
 exception when insufficient_privilege then null; end;
 begin
  delete from public.saved_views where id='f0736000-0000-4000-8000-000000000011'; get diagnostics changed=row_count;
  if changed<>0 then raise exception 'Anon delete allowed'; end if;
 exception when insufficient_privilege then null; end;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'f0736000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"f0736000-0000-4000-8000-000000000001","role":"authenticated"}', true);
do $$
declare changed integer;
begin
 if not exists(select 1 from public.saved_views where id='f0736000-0000-4000-8000-000000000011' and name='Renamed assigned name view' and query_ast->'root'->'children'->0->>'value'='M* Smith') then raise exception 'Assignment document overwritten'; end if;
 delete from public.saved_views where id='f0736000-0000-4000-8000-000000000011'; get diagnostics changed=row_count;
 if changed<>1 then raise exception 'Owner delete failed'; end if;
end $$;
rollback;
select (select count(*) from auth.users where id in ('f0736000-0000-4000-8000-000000000001','f0736000-0000-4000-8000-000000000002')) as fixture_users,
       (select count(*) from public.saved_views where id in ('f0736000-0000-4000-8000-000000000011','f0736000-0000-4000-8000-000000000012','f0736000-0000-4000-8000-000000000013')) as fixture_views;
