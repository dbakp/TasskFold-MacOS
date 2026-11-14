-- Disposable accounts/tasks only. Run as postgres, after 20261114120000_task_dependencies_lite.sql.
-- Always rolls back. Reserved UUID prefix f0dec0de-; example.invalid identities only.
-- Cast: A owns everything and shares project S with B (accepted). C is an outsider.
-- Tasks: s1, s2, s3 live in the shared project S; p1 lives in A's private project P; a1 is A's personal task.
begin;
insert into auth.users(id,email) values
 ('f0dec0de-0000-4000-8000-00000000000a','taskfold-deps-owner@example.invalid'),
 ('f0dec0de-0000-4000-8000-00000000000b','taskfold-deps-member@example.invalid'),
 ('f0dec0de-0000-4000-8000-00000000000c','taskfold-deps-outsider@example.invalid');
insert into public.projects(id,user_id,name) values
 ('f0dec0de-0000-4000-8000-0000000000e1','f0dec0de-0000-4000-8000-00000000000a','Shared'),
 ('f0dec0de-0000-4000-8000-0000000000e2','f0dec0de-0000-4000-8000-00000000000a','Private');
insert into public.project_collaborators(id,project_id,user_id,status) values
 ('f0dec0de-0000-4000-8000-0000000000f1','f0dec0de-0000-4000-8000-0000000000e1','f0dec0de-0000-4000-8000-00000000000b','accepted');
insert into public.tasks(id,user_id,title,project_id) values
 ('f0dec0de-0000-4000-8000-000000000051','f0dec0de-0000-4000-8000-00000000000a','s1','f0dec0de-0000-4000-8000-0000000000e1'),
 ('f0dec0de-0000-4000-8000-000000000052','f0dec0de-0000-4000-8000-00000000000a','s2','f0dec0de-0000-4000-8000-0000000000e1'),
 ('f0dec0de-0000-4000-8000-000000000053','f0dec0de-0000-4000-8000-00000000000a','s3','f0dec0de-0000-4000-8000-0000000000e1'),
 ('f0dec0de-0000-4000-8000-000000000061','f0dec0de-0000-4000-8000-00000000000a','p1','f0dec0de-0000-4000-8000-0000000000e2'),
 ('f0dec0de-0000-4000-8000-000000000071','f0dec0de-0000-4000-8000-00000000000a','a1',null);

-- Helpers run as the caller (security invoker) so they observe the caller's RLS view.
create function public.zz_expect(sql text, expected_state text, fragment text default '') returns void
language plpgsql as $$
begin
 begin execute sql;
 exception when others then
  if sqlstate <> expected_state or position(fragment in sqlerrm) = 0 then
   raise exception 'Wrong failure for [%]: % %', sql, sqlstate, sqlerrm; end if;
  return;
 end;
 raise exception 'Expected failure was not raised: %', sql;
end $$;
create function public.zz_count(sql text) returns bigint language plpgsql as $$
declare n bigint; begin execute sql into n; return n; end $$;
grant execute on function public.zz_expect(text,text,text), public.zz_count(text) to authenticated, anon;

-- Structure and privileges.
do $$ begin
 if not (select relrowsecurity from pg_class where oid='public.task_dependencies'::regclass) then raise exception 'RLS missing'; end if;
 if has_table_privilege('anon','public.task_dependencies','select') or has_table_privilege('anon','public.task_dependencies','insert') then raise exception 'anon has access'; end if;
 if has_table_privilege('authenticated','public.task_dependencies','update') then raise exception 'rows must be immutable'; end if;
 if not has_table_privilege('authenticated','public.task_dependencies','insert') or not has_table_privilege('authenticated','public.task_dependencies','delete') then raise exception 'authenticated cannot write'; end if;
 if has_function_privilege('authenticated','taskfold_private.guard_task_dependency()','execute') then raise exception 'trigger function exposed'; end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='task_dependencies') then raise exception 'Realtime publication missing'; end if;
 if not exists(select 1 from pg_constraint where conrelid='public.task_dependencies'::regclass and contype='u') then raise exception 'unique pair missing'; end if;
 if (select count(*) from pg_constraint where conrelid='public.task_dependencies'::regclass and contype='f' and confdeltype='c' and confrelid='public.tasks'::regclass) <> 2 then raise exception 'both task FKs must cascade'; end if;
end $$;

-- Operator-level constraints (no request identity): self block, unique pair, loop, cap.
do $$ begin
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000a','f0dec0de-0000-4000-8000-000000000051','f0dec0de-0000-4000-8000-000000000051')$q$,'23514','task_dependencies_no_self_block');
 insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000a','f0dec0de-0000-4000-8000-000000000051','f0dec0de-0000-4000-8000-000000000052');
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000a','f0dec0de-0000-4000-8000-000000000051','f0dec0de-0000-4000-8000-000000000052')$q$,'23505','task_dependencies_unique_pair');
 -- s1 <- s2 exists, so s2 <- s1 is a loop; so is s2 <- s3 once s3 <- s1 exists (transitive).
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000a','f0dec0de-0000-4000-8000-000000000052','f0dec0de-0000-4000-8000-000000000051')$q$,'23514','loop');
 insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000a','f0dec0de-0000-4000-8000-000000000053','f0dec0de-0000-4000-8000-000000000051');
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000a','f0dec0de-0000-4000-8000-000000000052','f0dec0de-0000-4000-8000-000000000053')$q$,'23514','loop');
 delete from public.task_dependencies where task_id='f0dec0de-0000-4000-8000-000000000053';
end $$;

-- Cap: ten blockers are accepted, the eleventh is refused; the cap is per blocked task.
do $$ declare i integer; blocked uuid := 'f0dec0de-0000-4000-8000-000000000071'; blocker uuid; begin
 for i in 1..10 loop
  blocker := ('f0dec0de-0000-4000-8000-0000000b' || lpad(i::text, 4, '0'))::uuid;
  insert into public.tasks(id,user_id,title) values(blocker,'f0dec0de-0000-4000-8000-00000000000a','cap ' || i);
  insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000a',blocked,blocker);
 end loop;
 insert into public.tasks(id,user_id,title) values('f0dec0de-0000-4000-8000-0000000b0011','f0dec0de-0000-4000-8000-00000000000a','cap 11');
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000a','f0dec0de-0000-4000-8000-000000000071','f0dec0de-0000-4000-8000-0000000b0011')$q$,'54000','at most 10');
 insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000a','f0dec0de-0000-4000-8000-000000000052','f0dec0de-0000-4000-8000-0000000b0011');
 delete from public.tasks where id::text like 'f0dec0de-0000-4000-8000-0000000b%';
 if (select count(*) from public.task_dependencies) <> 1 then raise exception 'Cascade on blocker delete failed'; end if;
 delete from public.task_dependencies;
end $$;

-- "Waiting on" note: nullable, 1..140 characters.
do $$ begin
 update public.tasks set waiting_on='Waiting on Anna''s reply' where title='s1';
 update public.tasks set waiting_on=repeat('x',140) where title='s2';
 update public.tasks set waiting_on=null where title='s2';
 perform public.zz_expect($q$update public.tasks set waiting_on=repeat('x',141) where title='s1'$q$,'23514','waiting_on');
 perform public.zz_expect($q$update public.tasks set waiting_on='' where title='s1'$q$,'23514','waiting_on');
 update public.tasks set waiting_on=null where title='s1';
end $$;

-- Sharing and access. A links s1 <- s2 (both shared) and s1 <- p1 (private blocker B cannot see).
select set_config('request.jwt.claim.sub','f0dec0de-0000-4000-8000-00000000000a',true);
set local role authenticated;
insert into public.task_dependencies(id,user_id,task_id,blocked_by_task_id) values
 ('f0dec0de-0000-4000-8000-0000000000d1',auth.uid(),'f0dec0de-0000-4000-8000-000000000051','f0dec0de-0000-4000-8000-000000000052'),
 ('f0dec0de-0000-4000-8000-0000000000d2',auth.uid(),'f0dec0de-0000-4000-8000-000000000051','f0dec0de-0000-4000-8000-000000000061');
-- Personal task blocked by a project task of the same owner.
insert into public.task_dependencies(id,user_id,task_id,blocked_by_task_id) values
 ('f0dec0de-0000-4000-8000-0000000000d3',auth.uid(),'f0dec0de-0000-4000-8000-000000000071','f0dec0de-0000-4000-8000-000000000053');
do $$ begin
 if public.zz_count('select count(*) from public.task_dependencies') <> 3 then raise exception 'Owner must read all rows'; end if;
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000b','f0dec0de-0000-4000-8000-000000000052','f0dec0de-0000-4000-8000-000000000053')$q$,'42501');
end $$;

select set_config('request.jwt.claim.sub','f0dec0de-0000-4000-8000-00000000000b',true);
do $$ begin
 -- B reads only the row between two tasks B can access; the private blocker's row is absent entirely.
 if public.zz_count('select count(*) from public.task_dependencies') <> 1 then raise exception 'Member must see exactly the shared row'; end if;
 if public.zz_count($q$select count(*) from public.task_dependencies where blocked_by_task_id='f0dec0de-0000-4000-8000-000000000061'$q$) <> 0 then raise exception 'Private blocker row leaked'; end if;
 if public.zz_count($q$select count(*) from public.task_dependencies where id='f0dec0de-0000-4000-8000-0000000000d3'$q$) <> 0 then raise exception 'Row on owner personal task leaked'; end if;
 -- Writes: blocker B cannot see, blocked task B cannot see, spoofed owner, personal task of another user.
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values(auth.uid(),'f0dec0de-0000-4000-8000-000000000052','f0dec0de-0000-4000-8000-000000000061')$q$,'42501');
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values(auth.uid(),'f0dec0de-0000-4000-8000-000000000061','f0dec0de-0000-4000-8000-000000000052')$q$,'42501');
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values(auth.uid(),'f0dec0de-0000-4000-8000-000000000071','f0dec0de-0000-4000-8000-000000000052')$q$,'42501');
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-00000000000a','f0dec0de-0000-4000-8000-000000000052','f0dec0de-0000-4000-8000-000000000053')$q$,'42501');
 -- The loop and cap guards do not run for rows the caller may not touch: no graph probing through errors.
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values(auth.uid(),'f0dec0de-0000-4000-8000-000000000061','f0dec0de-0000-4000-8000-000000000051')$q$,'42501');
 -- A legitimate collaborator write works and is visible to both, and a loop through shared tasks is refused.
 insert into public.task_dependencies(id,user_id,task_id,blocked_by_task_id) values('f0dec0de-0000-4000-8000-0000000000d4',auth.uid(),'f0dec0de-0000-4000-8000-000000000053','f0dec0de-0000-4000-8000-000000000052');
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values(auth.uid(),'f0dec0de-0000-4000-8000-000000000052','f0dec0de-0000-4000-8000-000000000053')$q$,'23514','loop');
 -- Rows are immutable; an invisible row cannot be deleted.
 perform public.zz_expect($q$update public.task_dependencies set blocked_by_task_id='f0dec0de-0000-4000-8000-000000000053' where id='f0dec0de-0000-4000-8000-0000000000d1'$q$,'42501');
 if public.zz_count($q$with d as (delete from public.task_dependencies where id='f0dec0de-0000-4000-8000-0000000000d2' returning 1) select count(*) from d$q$) <> 0 then raise exception 'Member deleted a row it cannot see'; end if;
end $$;

select set_config('request.jwt.claim.sub','f0dec0de-0000-4000-8000-00000000000c',true);
do $$ begin
 if public.zz_count('select count(*) from public.task_dependencies') <> 0 then raise exception 'Outsider must see nothing'; end if;
 perform public.zz_expect($q$insert into public.task_dependencies(user_id,task_id,blocked_by_task_id) values(auth.uid(),'f0dec0de-0000-4000-8000-000000000052','f0dec0de-0000-4000-8000-000000000053')$q$,'42501');
 if public.zz_count($q$with d as (delete from public.task_dependencies returning 1) select count(*) from d$q$) <> 0 then raise exception 'Outsider deleted rows'; end if;
end $$;

-- Anonymous callers have no privilege at all.
reset role;
set local role anon;
do $$ begin perform public.zz_expect('select count(*) from public.task_dependencies','42501'); end $$;

-- Back as the operator: the private row survived the member's attempt; revoking access hides rows.
reset role;
do $$ begin
 if (select count(*) from public.task_dependencies where id='f0dec0de-0000-4000-8000-0000000000d2') <> 1 then raise exception 'Row was removed by an unauthorised delete'; end if;
end $$;
delete from public.project_collaborators where id='f0dec0de-0000-4000-8000-0000000000f1';
select set_config('request.jwt.claim.sub','f0dec0de-0000-4000-8000-00000000000b',true);
set local role authenticated;
do $$ begin if public.zz_count('select count(*) from public.task_dependencies') <> 0 then raise exception 'Removed collaborator still reads dependencies'; end if; end $$;

-- Deleting a task cascades its links; deleting the owner account removes owner-created rows.
reset role;
delete from public.tasks where id='f0dec0de-0000-4000-8000-000000000052';
do $$ begin
 if exists(select 1 from public.task_dependencies where 'f0dec0de-0000-4000-8000-000000000052' in (task_id::text, blocked_by_task_id::text)) then raise exception 'Cascade on task delete failed'; end if;
end $$;
rollback;
