-- Disposable accounts/tasks only. Run as postgres, after the migration. Always rolls back.
begin;
-- Since Migration C (20261117110000_child_task_rows_c) subtasks are task rows with their own root provenance; the JSON
-- node provenance of the retired `subtasks` column is gone. assignment_nodes stays (project adoption still calls it).
insert into auth.users(id,email,raw_user_meta_data) values
 ('f01dcafe-8100-4000-8000-000000000001','taskfold-assignment-owner@example.invalid','{}'),
 ('f01dcafe-8100-4000-8000-000000000002','taskfold-assignment-member@example.invalid','{}'),
 ('f01dcafe-8100-4000-8000-000000000003','taskfold-assignment-outsider@example.invalid','{}');
do $$ declare tree jsonb; i integer; begin
 if has_table_privilege('authenticated','public.task_assignment_provenance','insert')
  or has_table_privilege('authenticated','public.task_assignment_provenance','update')
  or has_table_privilege('authenticated','public.task_assignment_provenance','delete')
  or has_table_privilege('anon','public.task_assignment_provenance','select')
  or has_function_privilege('authenticated','taskfold_private.capture_assignment_provenance()','execute')
  or has_function_privilege('authenticated','taskfold_private.assignment_nodes(jsonb)','execute') then raise exception 'Assignment writer exposed'; end if;
 if not (select relrowsecurity from pg_class where oid='public.task_assignment_provenance'::regclass) then raise exception 'Assignment RLS missing'; end if;
 if taskfold_private.assignment_nodes('[]')<>'{}'::jsonb or taskfold_private.assignment_nodes(null)<>'{}'::jsonb then raise exception 'Empty tree unknown'; end if;
 for tree in select value from jsonb_array_elements('[{},[1],[{"title":"Missing id"}],[{"id":"x","title":"X"},{"id":"x","title":"Duplicate"}],[{"id":"x","title":"X","assigned_to":"bad"}],[{"id":"x","title":"X","subtasks":{}}]]') loop
  if taskfold_private.assignment_nodes(tree) is not null then raise exception 'Unsupported tree accepted: %',tree; end if;
 end loop;
 if taskfold_private.assignment_nodes('[{"id":"A","title":"Upper","assigned_to":""},{"id":"a","title":"Lower"}]') is null then raise exception 'Case-sensitive child identities or empty assignment refused'; end if;
 tree:='[]';
 for i in 1..33 loop tree:=jsonb_build_array(jsonb_build_object('id',i::text,'title','Deep','subtasks',tree)); end loop;
 if taskfold_private.assignment_nodes(tree) is not null then raise exception 'Excess depth accepted'; end if;
 select jsonb_agg(jsonb_build_object('id',n.value::text,'title','Bounded')) into tree from generate_series(1,100001) n(value);
 if taskfold_private.assignment_nodes(tree) is not null then raise exception 'Excess node count accepted'; end if;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-8100-4000-8000-000000000001',true);
set local role authenticated;
insert into public.projects(id,user_id,name) values('f01dcafe-8100-4000-8000-000000000020',auth.uid(),'Assignment fixture');
insert into public.project_collaborators(id,project_id,invited_email,invited_by)
 values('f01dcafe-8100-4000-8000-000000000021','f01dcafe-8100-4000-8000-000000000020','taskfold-assignment-member@example.invalid',auth.uid());
select set_config('request.jwt.claim.sub','f01dcafe-8100-4000-8000-000000000002',true);
update public.project_collaborators set status='accepted' where id='f01dcafe-8100-4000-8000-000000000021';
select set_config('request.jwt.claim.sub','f01dcafe-8100-4000-8000-000000000001',true);
insert into public.tasks(id,user_id,title,project_id,assigned_to) values
 ('f01dcafe-8100-4000-8000-000000000010',auth.uid(),'Assignment proof','f01dcafe-8100-4000-8000-000000000020','f01dcafe-8100-4000-8000-000000000002');
-- A subtask row carries its own provenance.
insert into public.tasks(id,user_id,title,project_id,assigned_to,parent_id) values
 ('f01dcafe-8100-4000-8000-000000000015',auth.uid(),'Child row','f01dcafe-8100-4000-8000-000000000020','f01dcafe-8100-4000-8000-000000000002','f01dcafe-8100-4000-8000-000000000010');
do $$ begin
 if (select count(*) from public.task_assignment_provenance where task_id='f01dcafe-8100-4000-8000-000000000010')<>1 then raise exception 'Initial assigned scope wrong'; end if;
 if exists(select 1 from public.task_assignment_provenance where task_id in ('f01dcafe-8100-4000-8000-000000000010','f01dcafe-8100-4000-8000-000000000015') and (actor_id<>auth.uid() or origin<>'recorded' or assigned_at is null or node_key<>'')) then raise exception 'Creation actor/date wrong'; end if;
 if (select count(*) from public.task_assignment_provenance where task_id='f01dcafe-8100-4000-8000-000000000015')<>1 then raise exception 'Child row provenance missing'; end if;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-8100-4000-8000-000000000002',true);
update public.tasks set assigned_to='f01dcafe-8100-4000-8000-000000000001' where id='f01dcafe-8100-4000-8000-000000000010';
do $$ begin
 if (select count(*) from public.task_assignment_provenance where task_id='f01dcafe-8100-4000-8000-000000000010' and actor_id=auth.uid() and assignee_id='f01dcafe-8100-4000-8000-000000000001')<>1 then raise exception 'Member reassignment not recorded'; end if;
 begin
  update public.task_assignment_provenance set actor_id='f01dcafe-8100-4000-8000-000000000003';
  raise exception 'Client forged provenance';
 exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-8100-4000-8000-000000000001',true);
-- Simulate a row predating the migration, without modifying genuine user data.
reset role;
delete from public.task_assignment_provenance where task_id='f01dcafe-8100-4000-8000-000000000010';
set local role authenticated;
update public.tasks set title='Legacy renamed' where id='f01dcafe-8100-4000-8000-000000000010';
do $$ begin
 if (select count(*) from public.task_assignment_provenance where task_id='f01dcafe-8100-4000-8000-000000000010' and actor_id is null and origin='legacy')<>1 then raise exception 'Legacy title edit invented actor'; end if;
end $$;
insert into public.tasks(id,user_id,title,project_id,assigned_to,recurrence_parent_id,source_metadata) values
 ('f01dcafe-8100-4000-8000-000000000011',auth.uid(),'Recurring successor','f01dcafe-8100-4000-8000-000000000020','f01dcafe-8100-4000-8000-000000000001','f01dcafe-8100-4000-8000-000000000010','{"taskfold_recurrence_v1":{"action_id":"untrusted-client-marker"}}');
do $$ begin
 if (select count(*) from public.task_assignment_provenance where task_id='f01dcafe-8100-4000-8000-000000000011' and origin='recurrence' and actor_id is null)<>1 then raise exception 'Recurrence completer falsely became actor'; end if;
end $$;
-- Capture a real collaborator actor that can subsequently be removed.
insert into public.tasks(id,user_id,title,project_id,assigned_to) values('f01dcafe-8100-4000-8000-000000000013',auth.uid(),'Deleted actor proof','f01dcafe-8100-4000-8000-000000000020','f01dcafe-8100-4000-8000-000000000002');
select set_config('request.jwt.claim.sub','f01dcafe-8100-4000-8000-000000000002',true);
update public.tasks set assigned_to='f01dcafe-8100-4000-8000-000000000001' where id='f01dcafe-8100-4000-8000-000000000013';
do $$ begin
 if not exists(select 1 from public.task_assignment_provenance where task_id='f01dcafe-8100-4000-8000-000000000013' and actor_id=auth.uid() and origin='recorded') then raise exception 'Real actor deletion fixture not captured'; end if;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-8100-4000-8000-000000000001',true);
-- Access follows current task policies, including revocation, not actor/recipient identity.
update public.project_collaborators set status='declined' where id='f01dcafe-8100-4000-8000-000000000021';
select set_config('request.jwt.claim.sub','f01dcafe-8100-4000-8000-000000000002',true);
do $$ begin if exists(select 1 from public.task_assignment_provenance where task_id in ('f01dcafe-8100-4000-8000-000000000010','f01dcafe-8100-4000-8000-000000000011')) then raise exception 'Revoked actor retained provenance access'; end if; end $$;
select set_config('request.jwt.claim.sub','f01dcafe-8100-4000-8000-000000000003',true);
do $$ begin if exists(select 1 from public.task_assignment_provenance) then raise exception 'Outsider read provenance'; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub','',true);
insert into public.tasks(id,user_id,title,assigned_to) values('f01dcafe-8100-4000-8000-000000000012','f01dcafe-8100-4000-8000-000000000001','System fixture','f01dcafe-8100-4000-8000-000000000001');
do $$ begin
 if not exists(select 1 from public.task_assignment_provenance where task_id='f01dcafe-8100-4000-8000-000000000012' and actor_id is null and origin='system') then raise exception 'System actor guessed'; end if;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-8100-4000-8000-000000000001',true);
set local role authenticated;
do $$ declare generation uuid; begin
 select task_generation into generation from public.tasks where id='f01dcafe-8100-4000-8000-000000000012';
 delete from public.tasks where id='f01dcafe-8100-4000-8000-000000000012';
 insert into public.tasks(id,user_id,title,assigned_to) values('f01dcafe-8100-4000-8000-000000000012',auth.uid(),'New incarnation',auth.uid());
 if not exists(select 1 from public.task_assignment_provenance where task_id='f01dcafe-8100-4000-8000-000000000012' and task_generation<>generation and actor_id=auth.uid() and origin='recorded') then raise exception 'Restored incarnation reused old provenance'; end if;
end $$;
reset role;
-- Retain no actor profile/name; deleting that account makes the real actor unknown.
delete from auth.users where id='f01dcafe-8100-4000-8000-000000000002';
do $$ begin
 if not exists(select 1 from public.task_assignment_provenance where task_id='f01dcafe-8100-4000-8000-000000000013' and actor_id is null and assignee_id='f01dcafe-8100-4000-8000-000000000001' and origin='recorded') then raise exception 'Deleted actor retained or assignment lost'; end if;
end $$;
select jsonb_build_object('assignment_provenance_fixture','passed','scope','transactional SQL,roles/RLS,root and child-row transitions,unknown histories,generation and deletion');
rollback;
