-- Child task rows, Migration A (20261115100000_child_task_rows_a.sql). Disposable accounts and rows only.
-- Run as postgres against the full Taskfold schema (local `supabase db reset` or hosted acceptance).
-- One rolled-back transaction; reserved UUID prefix c41d0c0d-; example.invalid identities only.
-- Cast: A owns everything and shares project S (and D) with B (accepted). C is an outsider.
-- Projects: S shared, P and Q private to A, D shared and later deleted, TP and TQ are team projects.
begin;

create function public.zz_u(n integer) returns uuid language sql immutable as
$$ select ('c41d0c0d-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid $$;

insert into auth.users(id,email) values
 (public.zz_u(1),'taskfold-child-owner@example.invalid'),
 (public.zz_u(2),'taskfold-child-member@example.invalid'),
 (public.zz_u(3),'taskfold-child-outsider@example.invalid');
insert into public.projects(id,user_id,name) values
 (public.zz_u(100),public.zz_u(1),'S shared'),
 (public.zz_u(101),public.zz_u(1),'D shared, deleted later'),
 (public.zz_u(102),public.zz_u(1),'P private'),
 (public.zz_u(103),public.zz_u(1),'Q private'),
 (public.zz_u(104),public.zz_u(1),'TP team'),
 (public.zz_u(105),public.zz_u(1),'TQ team');
-- Genuine invitation lifecycle: the owner invites, the member accepts.
select set_config('request.jwt.claim.sub',public.zz_u(1)::text,true);
insert into public.project_collaborators(id,project_id,invited_email,invited_by) values
 (public.zz_u(110),public.zz_u(100),'taskfold-child-member@example.invalid',auth.uid()),
 (public.zz_u(111),public.zz_u(101),'taskfold-child-member@example.invalid',auth.uid());
select set_config('request.jwt.claim.sub',public.zz_u(2)::text,true);
update public.project_collaborators set status='accepted' where id in(public.zz_u(110),public.zz_u(111));
select set_config('request.jwt.claim.sub','',true);
insert into public.sections(id,user_id,project_id,name) values
 (public.zz_u(120),public.zz_u(1),public.zz_u(102),'P section'),
 (public.zz_u(121),public.zz_u(1),public.zz_u(103),'Q section');
-- Team custody is reached through the operator path: a team, its administrator, two team projects.
insert into taskfold_private.teams(id,owner_id,name) values (public.zz_u(130),public.zz_u(1),'Synthetic team');
insert into taskfold_private.team_members(team_id,user_id,role) values (public.zz_u(130),public.zz_u(1),'admin');
insert into taskfold_private.team_content_projects(project_id,team_id) values (public.zz_u(104),public.zz_u(130)),(public.zz_u(105),public.zz_u(130));

-- Helpers run as the caller (security invoker), so they observe the caller's RLS view.
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
-- Insert a task by number: zz_task(task, parent, project, owner, title). Project and parent 0 mean none.
create function public.zz_task(n integer, parent integer, project integer, owner integer, title text) returns void language plpgsql as $$
begin
 insert into public.tasks(id,user_id,title,project_id,parent_id)
 values(public.zz_u(n),public.zz_u(owner),title,case when project=0 then null else public.zz_u(project) end,case when parent=0 then null else public.zz_u(parent) end);
end $$;
-- Full baseline the way a current client would send it, optionally without the new keys (an old client).
create function public.zz_base(n integer, old_client boolean default false) returns jsonb language sql stable as $$
 select case when old_client then to_jsonb(t) - 'parent_id' - 'child_order' else to_jsonb(t) end from public.tasks t where id=public.zz_u(n) $$;
grant execute on function public.zz_u(integer), public.zz_expect(text,text,text), public.zz_count(text), public.zz_task(integer,integer,integer,integer,text), public.zz_base(integer,boolean) to authenticated, anon;

-- 1. Structure and privileges.
do $$ declare def text; begin
 if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='tasks' and column_name='parent_id' and data_type='uuid' and is_nullable='YES') then raise exception 'parent_id missing or not nullable'; end if;
 if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='tasks' and column_name='child_order' and data_type='double precision' and is_nullable='YES') then raise exception 'child_order missing or not nullable'; end if;
 if exists(select 1 from information_schema.columns where table_schema='public' and table_name='tasks' and column_name in('parent_id','child_order') and column_default is not null) then raise exception 'new columns must default to NULL'; end if;
 if not exists(select 1 from pg_constraint where conrelid='public.tasks'::regclass and conname='tasks_parent_not_self' and contype='c') then raise exception 'self-parent check missing'; end if;
 if not exists(select 1 from pg_constraint where conrelid='public.tasks'::regclass and conname='tasks_child_order_finite' and contype='c') then raise exception 'finite check missing'; end if;
 if not exists(select 1 from pg_constraint where conrelid='public.tasks'::regclass and contype='f' and confrelid='public.tasks'::regclass and confdeltype='c' and conkey=array[(select attnum from pg_attribute where attrelid='public.tasks'::regclass and attname='parent_id')]) then raise exception 'parent FK must cascade'; end if;
 if not exists(select 1 from pg_index i join pg_class c on c.oid=i.indexrelid where i.indrelid='public.tasks'::regclass and c.relname='tasks_children' and i.indpred is not null) then raise exception 'partial tasks_children index missing'; end if;
 if (select count(*) from pg_trigger where tgrelid='public.tasks'::regclass and tgname in('taskfold_guard_task_parent','taskfold_cascade_task_parent_move','taskfold_guard_team_parent_delete') and tgenabled='O') <> 3 then raise exception 'child task triggers missing'; end if;
 if has_function_privilege('authenticated','taskfold_private.guard_task_parent()','execute') or has_function_privilege('anon','taskfold_private.guard_task_parent()','execute')
    or has_function_privilege('authenticated','taskfold_private.cascade_task_parent_move()','execute')
    or has_function_privilege('authenticated','taskfold_private.guard_team_parent_delete()','execute') then raise exception 'trigger functions exposed'; end if;
 if not (select prosecdef from pg_proc where oid='taskfold_private.guard_task_parent()'::regprocedure) or (select proconfig from pg_proc where oid='taskfold_private.guard_task_parent()'::regprocedure) is distinct from array['search_path=""'] then raise exception 'guard must be security definer with an empty search_path'; end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='tasks') then raise exception 'tasks must stay in the Realtime publication'; end if;
 -- The patched editor: marker survives, new keys allowed, endpoint grants unchanged.
 def := pg_get_functiondef('public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure);
 if position('TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1' in def) = 0 then raise exception 'scoped-assignment marker lost'; end if;
 if position('TASKFOLD_CHILD_PARENT_CONFLICT_V1' in def) = 0 then raise exception 'parent conflict rule missing'; end if;
 if position(',''is_heading'',''parent_id'',''child_order'',''waiting_on'']' in def) = 0 then raise exception 'allowlist not extended'; end if;
 if position('parent_id=t.parent_id,child_order=t.child_order,waiting_on=t.waiting_on where id=_id' in def) = 0 then raise exception 'update list not extended'; end if;
 if not has_function_privilege('authenticated','public.taskfold_patch_task(uuid,jsonb,jsonb)','execute') or has_function_privilege('anon','public.taskfold_patch_task(uuid,jsonb,jsonb)','execute') then raise exception 'taskfold_patch_task grants changed'; end if;
 if not exists(select 1 from pg_proc where oid='public.taskfold_assign_task_scoped(uuid,jsonb,jsonb)'::regprocedure and has_function_privilege('authenticated',oid,'execute')) then raise exception 'scoped assignment endpoint lost its grant'; end if;
end $$;

-- 2. Operator-level constraints and defaults (no request identity).
do $$ begin
 perform public.zz_task(1000,0,102,1,'root');
 perform public.zz_expect($q$update public.tasks set parent_id=id where id=public.zz_u(1000)$q$,'23514','own subtask');
 perform public.zz_expect($q$select public.zz_task(1001,999999,102,1,'orphan')$q$,'23503','parent task is not available');
 perform public.zz_expect($q$select public.zz_task(1001,1000,103,1,'wrong project')$q$,'23514','same project');
 perform public.zz_expect($q$select public.zz_task(1001,1000,0,1,'inbox child of a project task')$q$,'23514','same project');
 -- A root never carries an order, even when one is supplied.
 insert into public.tasks(id,user_id,title,project_id,child_order) values(public.zz_u(1002),public.zz_u(1),'root with order',public.zz_u(102),5);
 if (select child_order from public.tasks where id=public.zz_u(1002)) is not null then raise exception 'root kept a child_order'; end if;
 -- Append defaults to max + 1, an explicit order is kept, the next append follows it.
 perform public.zz_task(1010,1000,102,1,'first');
 perform public.zz_expect($q$update public.tasks set child_order='NaN' where id=public.zz_u(1010)$q$,'23514','tasks_child_order_finite');
 perform public.zz_expect($q$update public.tasks set child_order='Infinity' where id=public.zz_u(1010)$q$,'23514','tasks_child_order_finite');
 perform public.zz_expect($q$update public.tasks set child_order='-Infinity' where id=public.zz_u(1010)$q$,'23514','tasks_child_order_finite');
 perform public.zz_task(1011,1000,102,1,'second');
 insert into public.tasks(id,user_id,title,project_id,parent_id,child_order) values(public.zz_u(1012),public.zz_u(1),'explicit',public.zz_u(102),public.zz_u(1000),10);
 perform public.zz_task(1013,1000,102,1,'after explicit');
 if (select array_agg(child_order order by id) from public.tasks where parent_id=public.zz_u(1000)) is distinct from array[1,2,10,11]::float8[] then raise exception 'unexpected child orders %', (select array_agg(child_order order by id) from public.tasks where parent_id=public.zz_u(1000)); end if;
 -- Detaching clears the order; re-attaching appends.
 update public.tasks set parent_id=null where id=public.zz_u(1013);
 if (select child_order from public.tasks where id=public.zz_u(1013)) is not null then raise exception 'detach kept child_order'; end if;
 update public.tasks set parent_id=public.zz_u(1000) where id=public.zz_u(1013);
 if (select child_order from public.tasks where id=public.zz_u(1013)) <> 11 then raise exception 're-attach did not append'; end if;
 -- A personal (inbox) child must belong to the same owner as its parent.
 perform public.zz_task(1020,0,0,1,'inbox root');
 perform public.zz_expect($q$select public.zz_task(1021,1020,0,2,'other owner child')$q$,'23514','same project');
 perform public.zz_task(1021,1020,0,1,'inbox child');
 delete from public.tasks where id in(public.zz_u(1000),public.zz_u(1002),public.zz_u(1020));
 if exists(select 1 from public.tasks where id in(public.zz_u(1010),public.zz_u(1021))) then raise exception 'cascade did not remove children'; end if;
end $$;

-- 3. Depth and cycles. Depth is the number of levels below the root: ten is allowed, eleven is not.
do $$ declare i integer; begin
 perform public.zz_task(1100,0,102,1,'r0');
 for i in 1..10 loop perform public.zz_task(1100+i,1100+i-1,102,1,'c'||i); end loop;
 perform public.zz_expect($q$select public.zz_task(1111,1110,102,1,'c11')$q$,'54000','at most 10 levels');
 -- A moved subtree counts with its own height: a root with a two-level subtree fits under c7 (deepest at 10), not under c8.
 perform public.zz_task(1200,0,102,1,'s0'); perform public.zz_task(1201,1200,102,1,'s1'); perform public.zz_task(1202,1201,102,1,'s2');
 perform public.zz_expect($q$update public.tasks set parent_id=public.zz_u(1108) where id=public.zz_u(1200)$q$,'54000','at most 10 levels');
 update public.tasks set parent_id=public.zz_u(1107) where id=public.zz_u(1200);
 if (select count(*) from public.tasks where parent_id=public.zz_u(1107)) <> 2 then raise exception 'subtree move under c7 failed'; end if;
 perform public.zz_expect($q$select public.zz_task(1203,1202,102,1,'one level too deep')$q$,'54000','at most 10 levels');
 -- Cycles: a task under its own descendant, directly and through the chain, and a two-task loop.
 perform public.zz_expect($q$update public.tasks set parent_id=public.zz_u(1103) where id=public.zz_u(1100)$q$,'23514','own subtask');
 perform public.zz_expect($q$update public.tasks set parent_id=public.zz_u(1202) where id=public.zz_u(1200)$q$,'23514','own subtask');
 perform public.zz_expect($q$update public.tasks set parent_id=public.zz_u(1103) where id=public.zz_u(1103)$q$,'23514','own subtask');
 perform public.zz_task(1300,0,102,1,'x'); perform public.zz_task(1301,1300,102,1,'y');
 perform public.zz_expect($q$update public.tasks set parent_id=public.zz_u(1301) where id=public.zz_u(1300)$q$,'23514','own subtask');
 delete from public.tasks where id in(public.zz_u(1100),public.zz_u(1300));
 if exists(select 1 from public.tasks where id in(public.zz_u(1110),public.zz_u(1202),public.zz_u(1301))) then raise exception 'deep cascade delete failed'; end if;
end $$;

-- 4. Cascade move: project and section follow the parent, through every level.
do $$ declare n integer; begin
 perform public.zz_task(1400,0,102,1,'m0'); perform public.zz_task(1401,1400,102,1,'m1'); perform public.zz_task(1402,1401,102,1,'m2'); perform public.zz_task(1403,1400,102,1,'m1b');
 update public.tasks set project_id=public.zz_u(103), section_id=public.zz_u(121) where id=public.zz_u(1400);
 select count(*) into n from public.tasks where id between public.zz_u(1400) and public.zz_u(1403) and project_id=public.zz_u(103) and section_id=public.zz_u(121);
 if n <> 4 then raise exception 'cascade move reached % of 4 tasks', n; end if;
 -- Section-only change follows too; back to the inbox keeps the links (same owner).
 update public.tasks set section_id=null where id=public.zz_u(1400);
 if exists(select 1 from public.tasks where id between public.zz_u(1401) and public.zz_u(1403) and section_id is not null) then raise exception 'section did not cascade'; end if;
 update public.tasks set project_id=null where id=public.zz_u(1400);
 if (select count(*) from public.tasks where id between public.zz_u(1400) and public.zz_u(1403) and project_id is null) <> 4 then raise exception 'cascade to inbox failed'; end if;
 if (select count(*) from public.tasks where parent_id is not null and id between public.zz_u(1400) and public.zz_u(1403)) <> 3 then raise exception 'links lost on move'; end if;
 update public.tasks set project_id=public.zz_u(102) where id=public.zz_u(1400);
 -- A child cannot leave its parent's project while staying a child; detaching and moving in one write is fine.
 perform public.zz_expect($q$update public.tasks set project_id=public.zz_u(103) where id=public.zz_u(1402)$q$,'23514','same project');
 update public.tasks set parent_id=null, project_id=public.zz_u(103) where id=public.zz_u(1402);
 if (select child_order from public.tasks where id=public.zz_u(1402)) is not null or (select project_id from public.tasks where id=public.zz_u(1402)) <> public.zz_u(103) then raise exception 'detach and move failed'; end if;
 delete from public.tasks where id in(public.zz_u(1400),public.zz_u(1402));
end $$;

-- 4b. Interaction with guard_task: assignee clearing applies to children moved by the cascade.
do $$ begin
 insert into public.tasks(id,user_id,title,project_id,assigned_to) values(public.zz_u(1500),public.zz_u(1),'assigned parent',public.zz_u(100),public.zz_u(2));
 insert into public.tasks(id,user_id,title,project_id,parent_id,assigned_to) values(public.zz_u(1501),public.zz_u(1),'assigned child',public.zz_u(100),public.zz_u(1500),public.zz_u(2));
 update public.tasks set project_id=public.zz_u(102) where id=public.zz_u(1500);
 if exists(select 1 from public.tasks where id in(public.zz_u(1500),public.zz_u(1501)) and (assigned_to is not null or project_id<>public.zz_u(102))) then raise exception 'assignee not cleared on cascade move'; end if;
 delete from public.tasks where id=public.zz_u(1500);
end $$;

-- 4c. Interaction with recording custody (taskfold_audio_task_move): a child with a live recording blocks the whole move.
do $$ declare gen uuid; begin
 perform public.zz_task(1600,0,102,1,'audio parent'); perform public.zz_task(1601,1600,102,1,'audio child');
 select task_generation into gen from public.tasks where id=public.zz_u(1601);
 insert into taskfold_private.audio_comment_publications(operation_id,comment_id,asset_id,author_id,task_id,task_generation,project_id,request_hash,sha256,byte_count,caption,audio_descriptor,state,published_at)
  values(public.zz_u(1610),public.zz_u(1611),public.zz_u(1612),public.zz_u(1),public.zz_u(1601),gen,public.zz_u(102),decode(repeat('00',32),'hex'),repeat('0',64),1,'synthetic','{}','published',now());
 perform public.zz_expect($q$update public.tasks set project_id=public.zz_u(103) where id=public.zz_u(1600)$q$,'23514','recording custody');
 if (select project_id from public.tasks where id=public.zz_u(1600)) <> public.zz_u(102) or (select project_id from public.tasks where id=public.zz_u(1601)) <> public.zz_u(102) then raise exception 'blocked move was not rolled back'; end if;
 -- Deleting the parent cascades the child and retires its recording like any task deletion.
 delete from public.tasks where id=public.zz_u(1600);
 if (select state from taskfold_private.audio_comment_publications where operation_id=public.zz_u(1610)) <> 'retired' then raise exception 'cascade delete did not retire the child recording'; end if;
 delete from taskfold_private.audio_comment_publications where operation_id=public.zz_u(1610);
end $$;

-- 4d. Project deletion sets project_id to NULL row by row; it must not trip over the same-project rule.
do $$ begin
 insert into public.tasks(id,user_id,title,project_id) values(public.zz_u(1700),public.zz_u(1),'same-owner parent',public.zz_u(103));
 insert into public.tasks(id,user_id,title,project_id,parent_id) values(public.zz_u(1701),public.zz_u(1),'same-owner child',public.zz_u(103),public.zz_u(1700));
 insert into public.tasks(id,user_id,title,project_id) values(public.zz_u(1710),public.zz_u(1),'owner parent in shared project',public.zz_u(101));
 insert into public.tasks(id,user_id,title,project_id,parent_id) values(public.zz_u(1711),public.zz_u(2),'member child in shared project',public.zz_u(101),public.zz_u(1710));
 delete from public.projects where id in(public.zz_u(103),public.zz_u(101));
 if (select parent_id from public.tasks where id=public.zz_u(1701)) is distinct from public.zz_u(1700) then raise exception 'same-owner link lost on project deletion'; end if;
 if (select parent_id from public.tasks where id=public.zz_u(1711)) is not null or (select child_order from public.tasks where id=public.zz_u(1711)) is not null then raise exception 'cross-owner child must detach when the shared project goes away'; end if;
 if exists(select 1 from public.tasks where id in(public.zz_u(1700),public.zz_u(1701),public.zz_u(1710),public.zz_u(1711)) and project_id is not null) then raise exception 'project deletion did not clear project_id'; end if;
 delete from public.tasks where id in(public.zz_u(1700),public.zz_u(1710),public.zz_u(1711));
 insert into public.projects(id,user_id,name) values(public.zz_u(103),public.zz_u(1),'Q private');
end $$;

-- 5. RLS and the guard as real callers.
select set_config('request.jwt.claim.sub',public.zz_u(1)::text,true);
set local role authenticated;
do $$ begin
 perform public.zz_task(2000,0,100,1,'shared parent');
 perform public.zz_task(2001,2000,100,1,'owner child');
 perform public.zz_task(2010,0,102,1,'private parent');
 perform public.zz_task(2020,0,0,1,'inbox parent');
 -- Own tree in another project, and across projects, is refused.
 perform public.zz_expect($q$select public.zz_task(2002,2010,100,1,'child in the wrong project')$q$,'23514','same project');
 perform public.zz_expect($q$update public.tasks set parent_id=public.zz_u(2010) where id=public.zz_u(2001)$q$,'23514','same project');
 perform public.zz_expect($q$update public.tasks set parent_id=public.zz_u(2020) where id=public.zz_u(2001)$q$,'23514','same project');
 if public.zz_count('select count(*) from public.tasks where parent_id is not null') <> 1 then raise exception 'Owner must see exactly the permitted child'; end if;
end $$;

select set_config('request.jwt.claim.sub',public.zz_u(2)::text,true);
do $$ begin
 -- B is a member of S: reads the tree, adds a child under A's parent, reorders and detaches it.
 if public.zz_count('select count(*) from public.tasks where project_id=public.zz_u(100)') <> 2 then raise exception 'Member must see the shared tree'; end if;
 perform public.zz_task(2003,2000,100,2,'member child');
 if (select child_order from public.tasks where id=public.zz_u(2003)) <> 2 then raise exception 'Member child must append'; end if;
 update public.tasks set child_order=0.5 where id=public.zz_u(2003);
 -- The parent is invisible: the answer is identical for a task B cannot read and for an id that does not exist.
 perform public.zz_expect($q$select public.zz_task(2004,2010,102,2,'child of an invisible task')$q$,'23503','parent task is not available');
 perform public.zz_expect($q$select public.zz_task(2004,999999,102,2,'child of nothing')$q$,'23503','parent task is not available');
 perform public.zz_expect($q$update public.tasks set parent_id=public.zz_u(2010) where id=public.zz_u(2003)$q$,'23503','parent task is not available');
 -- B cannot create a child in a project it has no access to even with an existing parent id (RLS or guard, never success).
 perform public.zz_expect($q$select public.zz_task(2005,2010,102,2,'private project child')$q$,'23503');
 update public.tasks set parent_id=null where id=public.zz_u(2003);
 if (select child_order from public.tasks where id=public.zz_u(2003)) is not null then raise exception 'Member detach kept child_order'; end if;
end $$;

select set_config('request.jwt.claim.sub',public.zz_u(3)::text,true);
do $$ begin
 if public.zz_count('select count(*) from public.tasks') <> 0 then raise exception 'Outsider must see nothing'; end if;
 perform public.zz_expect($q$select public.zz_task(2006,2000,100,3,'outsider child of a shared task')$q$,'23503','parent task is not available');
 perform public.zz_expect($q$select public.zz_task(2006,2020,0,3,'outsider child of an inbox task')$q$,'23503','parent task is not available');
 if public.zz_count($q$with u as (update public.tasks set parent_id=public.zz_u(2000) where id=public.zz_u(2001) returning 1) select count(*) from u$q$) <> 0 then raise exception 'Outsider updated a child'; end if;
 if public.zz_count($q$with d as (delete from public.tasks where id=public.zz_u(2001) returning 1) select count(*) from d$q$) <> 0 then raise exception 'Outsider deleted a child'; end if;
end $$;

-- A deletes the shared tree through DELETE: the cascade removes B's child as well.
select set_config('request.jwt.claim.sub',public.zz_u(1)::text,true);
do $$ begin
 perform public.zz_task(2007,2000,100,1,'owner child 2');
 perform public.zz_task(2008,2007,100,1,'grandchild');
 if public.zz_count($q$with d as (delete from public.tasks where id=public.zz_u(2000) returning 1) select count(*) from d$q$) <> 1 then raise exception 'Parent delete should affect one visible row'; end if;
 -- B's detached task 2003 is a root now and stays; the three real children are gone.
 if public.zz_count($q$select count(*) from public.tasks where project_id=public.zz_u(100)$q$) <> 1 or public.zz_count($q$select count(*) from public.tasks where id=public.zz_u(2003)$q$) <> 1 then raise exception 'Children survived the cascade'; end if;
end $$;

reset role;
set local role anon;
do $$ begin perform public.zz_expect('select count(*) from public.tasks','42501'); end $$;
reset role;

-- 6. Cascade delete: history, generations and webhooks per deleted child, personal tree.
do $$ declare hook uuid := public.zz_u(3000); before_gen bigint; before_act bigint; begin
 insert into taskfold_private.webhook_subscriptions(id,user_id,name,endpoint,scope,events,ttl_days,secret_hash,secret_envelope,state,expires_at,verified_at)
  values(hook,public.zz_u(1),'Synthetic hook','https://receiver.example.invalid/events','all',array['task.deleted'],30,repeat('d',64),'{}','active',now()+interval '1 day',now());
 perform public.zz_task(3100,0,102,1,'w0'); perform public.zz_task(3101,3100,102,1,'w1'); perform public.zz_task(3102,3101,102,1,'w2');
 select count(*) into before_gen from taskfold_private.task_generations where task_id between public.zz_u(3100) and public.zz_u(3102);
 if before_gen <> 3 then raise exception 'expected 3 recorded generations, got %', before_gen; end if;
 delete from public.tasks where id=public.zz_u(3100);
 if exists(select 1 from public.tasks where id between public.zz_u(3100) and public.zz_u(3102)) then raise exception 'cascade delete left tasks behind'; end if;
 if (select count(*) from taskfold_private.webhook_outbox where subscription_id=hook and event_type='task.deleted' and task_id between public.zz_u(3100) and public.zz_u(3102)) <> 3 then
  raise exception 'expected one task.deleted webhook per deleted task, got %', (select count(*) from taskfold_private.webhook_outbox where subscription_id=hook and event_type='task.deleted'); end if;
end $$;

-- 6b. Old-client DELETE baselines (taskfold_delete_task) without the new keys.
select set_config('request.jwt.claim.sub',public.zz_u(1)::text,true);
set local role authenticated;
do $$ begin
 perform public.zz_task(3200,0,102,1,'old client root');
 -- Old client, root task: the baseline lacks parent_id and child_order, which are NULL for a root, so it still matches.
 if not public.taskfold_delete_task(public.zz_u(3200), public.zz_base(3200,true)) then raise exception 'old-client root delete failed'; end if;
 if public.zz_count($q$select count(*) from public.tasks where id=public.zz_u(3200)$q$) <> 0 then raise exception 'root was not deleted'; end if;
 -- A child is a different shape: an old baseline conflicts (expected: old builds see a conflict, not silent data loss).
 perform public.zz_task(3210,0,102,1,'parent'); perform public.zz_task(3211,3210,102,1,'child');
 perform public.zz_expect($q$select public.taskfold_delete_task(public.zz_u(3211), public.zz_base(3211,true))$q$,'P0001','TASKFOLD_CONFLICT');
 if public.zz_count($q$select count(*) from public.tasks where id=public.zz_u(3211)$q$) <> 1 then raise exception 'conflicting delete removed the child'; end if;
 -- A new client sends the full baseline and the child goes.
 if not public.taskfold_delete_task(public.zz_u(3211), public.zz_base(3211)) then raise exception 'new-client child delete failed'; end if;
 -- Deleting the parent with a baseline cascades whatever remains.
 perform public.zz_task(3212,3210,102,1,'child 2');
 if not public.taskfold_delete_task(public.zz_u(3210), public.zz_base(3210,true)) then raise exception 'old-client parent delete failed'; end if;
 if public.zz_count($q$select count(*) from public.tasks where id in(public.zz_u(3210),public.zz_u(3212))$q$) <> 0 then raise exception 'parent delete left a child'; end if;
end $$;

-- 7. taskfold_patch_task: old-client PATCH baselines, the new keys, the parent conflict rule and waiting_on.
do $$ declare t public.tasks; begin
 perform public.zz_task(4000,0,102,1,'patch root'); perform public.zz_task(4001,0,102,1,'patch other root'); perform public.zz_task(4002,0,102,1,'patch third root');
 perform public.zz_task(4010,4000,102,1,'patch child');
 -- Old client: title and priority with an old-shape baseline, on a root and on a child.
 t := public.taskfold_patch_task(public.zz_u(4000), public.zz_base(4000,true), '{"title":"renamed","priority":2}'::jsonb);
 if t.title <> 'renamed' or t.priority <> 2 or t.parent_id is not null then raise exception 'old-client root patch failed'; end if;
 t := public.taskfold_patch_task(public.zz_u(4010), public.zz_base(4010,true), '{"title":"renamed child"}'::jsonb);
 if t.title <> 'renamed child' or t.parent_id <> public.zz_u(4000) or t.child_order <> 1 then raise exception 'old-client child patch changed the structure'; end if;
 -- The allowlist still rejects everything else.
 perform public.zz_expect($q$select public.taskfold_patch_task(public.zz_u(4000), public.zz_base(4000), '{"user_id":"c41d0c0d-0000-4000-8000-000000000002"}'::jsonb)$q$,'P0001','cannot be edited');
 perform public.zz_expect($q$select public.taskfold_patch_task(public.zz_u(4000), public.zz_base(4000,true), jsonb_build_object('parent_id',public.zz_u(4001)))$q$,'P0001','baseline is required');
 -- Reorder, move under another parent, detach.
 t := public.taskfold_patch_task(public.zz_u(4010), public.zz_base(4010), '{"child_order":2.5}'::jsonb);
 if t.child_order <> 2.5 then raise exception 'child_order patch failed'; end if;
 t := public.taskfold_patch_task(public.zz_u(4010), public.zz_base(4010), jsonb_build_object('parent_id',public.zz_u(4001),'child_order',1));
 if t.parent_id <> public.zz_u(4001) or t.child_order <> 1 then raise exception 'reparent patch failed'; end if;
 perform public.zz_expect($q$select public.taskfold_patch_task(public.zz_u(4010), public.zz_base(4010), jsonb_build_object('parent_id',public.zz_u(4010)))$q$,'23514','own subtask');
 perform public.zz_expect($q$select public.taskfold_patch_task(public.zz_u(4001), public.zz_base(4001), jsonb_build_object('parent_id',public.zz_u(4010)))$q$,'23514','own subtask');
 -- Three-way parent rule: base = root, another device moved it under 4001, this device wants 4002 -> conflict.
 perform public.zz_expect($q$select public.taskfold_patch_task(public.zz_u(4010), jsonb_set(public.zz_base(4010),'{parent_id}','null'), jsonb_build_object('parent_id',public.zz_u(4002)))$q$,'PT409','different parent');
 -- A retry of the same move (remote already equals the desired value) is idempotent.
 t := public.taskfold_patch_task(public.zz_u(4010), jsonb_set(public.zz_base(4010),'{parent_id}','null'), jsonb_build_object('parent_id',public.zz_u(4001)));
 if t.parent_id <> public.zz_u(4001) then raise exception 'idempotent move retry failed'; end if;
 -- A stale detach whose baseline is current applies.
 t := public.taskfold_patch_task(public.zz_u(4010), public.zz_base(4010), '{"parent_id":null}'::jsonb);
 if t.parent_id is not null or t.child_order is not null then raise exception 'detach patch failed'; end if;
 -- waiting_on: the bug fix. Set, conflict on a stale baseline, clear, length limit.
 t := public.taskfold_patch_task(public.zz_u(4000), public.zz_base(4000), '{"waiting_on":"Waiting on Anna"}'::jsonb);
 if t.waiting_on <> 'Waiting on Anna' then raise exception 'waiting_on patch failed'; end if;
 perform public.zz_expect($q$select public.taskfold_patch_task(public.zz_u(4000), jsonb_set(public.zz_base(4000),'{waiting_on}','null'), '{"waiting_on":"Waiting on Bo"}'::jsonb)$q$,'P0001','TASKFOLD_CONFLICT');
 t := public.taskfold_patch_task(public.zz_u(4000), public.zz_base(4000), '{"waiting_on":null}'::jsonb);
 if t.waiting_on is not null then raise exception 'waiting_on clear failed'; end if;
 perform public.zz_expect($q$select public.taskfold_patch_task(public.zz_u(4000), public.zz_base(4000), jsonb_build_object('waiting_on',repeat('x',141)))$q$,'23514','waiting_on');
 -- The scoped-assignment guard still answers: the task's project is part of the saved baseline.
 perform public.zz_expect($q$select public.taskfold_patch_task(public.zz_u(4000), jsonb_set(public.zz_base(4000),'{project_id}',to_jsonb(public.zz_u(103)::text)), jsonb_build_object('assigned_to',public.zz_u(1),'project_id',public.zz_u(103)))$q$,'PT409','This task moved');
 t := public.taskfold_assign_task_scoped(public.zz_u(4000), public.zz_base(4000), jsonb_build_object('assigned_to',public.zz_u(1),'project_id',public.zz_u(102)));
 if t.assigned_to is distinct from public.zz_u(1) then raise exception 'scoped assignment endpoint failed'; end if;
 -- Moving a parent through the PATCH endpoint moves its children.
 perform public.zz_task(4020,4000,102,1,'follows its parent');
 t := public.taskfold_patch_task(public.zz_u(4000), public.zz_base(4000), jsonb_build_object('project_id',public.zz_u(103)));
 if (select project_id from public.tasks where id=public.zz_u(4020)) is distinct from public.zz_u(103) then raise exception 'PATCH move did not cascade'; end if;
 delete from public.tasks where id in(public.zz_u(4000),public.zz_u(4001),public.zz_u(4002));
end $$;
reset role;

select set_config('request.jwt.claim.sub','',true);
-- 8. Team projects. Nothing creates team child rows before phase T, so the migration must leave the closed-content
-- guard untouched and refuse the one dangerous path: a cascade that would delete team children without their custody.
do $$ begin
 perform public.zz_task(5000,0,104,1,'team parent'); perform public.zz_task(5001,5000,104,1,'team child'); perform public.zz_task(5002,5001,104,1,'team grandchild');
 if (select count(*) from taskfold_private.team_content_tasks where task_id between public.zz_u(5000) and public.zz_u(5002)) <> 3 then raise exception 'team custody rows missing'; end if;
 -- A team child cannot be created in a different project than its team parent.
 perform public.zz_expect($q$select public.zz_task(5003,5000,105,1,'cross team project child')$q$,'23514','same project');
 -- With a request subject and a valid delete scope for the parent only (what the team delete endpoint gives), the cascade is refused.
 perform set_config('request.jwt.claim.sub',public.zz_u(1)::text,true);
 insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation)
  select txid_current(),public.zz_u(130),public.zz_u(104),id,task_generation,public.zz_u(1),'delete' from public.tasks where id=public.zz_u(5000);
 perform public.zz_expect($q$delete from public.tasks where id=public.zz_u(5000)$q$,'PT409','Remove the subtasks of this team task');
 if (select count(*) from public.tasks where id between public.zz_u(5000) and public.zz_u(5002)) <> 3 then raise exception 'refused team delete changed data'; end if;
 -- Without a scope the existing closed-content guard still refuses first.
 delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current();
 perform public.zz_expect($q$delete from public.tasks where id=public.zz_u(5000)$q$,'PT503');
 -- A team leaf (no children) is untouched by the new guard: only the existing scope rules decide.
 perform public.zz_expect($q$delete from public.tasks where id=public.zz_u(5002)$q$,'PT503');
 -- The cascade moves children of a team parent only under a team move scope: unscoped, the closed guard refuses with a subject.
 perform public.zz_expect($q$update public.tasks set project_id=public.zz_u(105) where id=public.zz_u(5000)$q$,'PT503');
 perform set_config('request.jwt.claim.sub','',true);
 -- SQL operators without a subject stay trusted: the move cascades and the delete cascades.
 update public.tasks set project_id=public.zz_u(105) where id=public.zz_u(5000);
 if (select count(*) from public.tasks where id between public.zz_u(5000) and public.zz_u(5002) and project_id=public.zz_u(105)) <> 3 then raise exception 'operator move of a team tree did not cascade'; end if;
 delete from public.tasks where id=public.zz_u(5000);
 if exists(select 1 from public.tasks where id between public.zz_u(5000) and public.zz_u(5002)) then raise exception 'operator delete of a team tree left children'; end if;
end $$;

rollback;
