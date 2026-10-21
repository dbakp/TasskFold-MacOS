begin;
insert into auth.users(id,email) values
 ('f1791000-0000-4000-8000-000000000001','conversation-count-owner@example.invalid'),
 ('f1791000-0000-4000-8000-000000000002','conversation-count-member@example.invalid'),
 ('f1791000-0000-4000-8000-000000000003','conversation-count-outsider@example.invalid');
set local role authenticated;
set local request.jwt.claim.sub='f1791000-0000-4000-8000-000000000001';
insert into public.projects(id,name) values('f1792000-0000-4000-8000-000000000001','Count fixture');
insert into public.tasks(id,user_id,title,project_id) values('f1793000-0000-4000-8000-000000000001',auth.uid(),'Count task','f1792000-0000-4000-8000-000000000001');
reset role;
insert into public.project_collaborators(project_id,user_id,invited_email,role,status,invited_by)
 values('f1792000-0000-4000-8000-000000000001','f1791000-0000-4000-8000-000000000002','conversation-count-member@example.invalid','collaborator','pending','f1791000-0000-4000-8000-000000000001');
set local role authenticated;
set local request.jwt.claim.sub='f1791000-0000-4000-8000-000000000002';
update public.project_collaborators set status='accepted' where user_id=auth.uid();
set local request.jwt.claim.sub='f1791000-0000-4000-8000-000000000001';
select public.taskfold_write_comment(gen_random_uuid(),'f1795000-0000-4000-8000-000000000001','f1793000-0000-4000-8000-000000000001',(select task_generation from public.tasks where id='f1793000-0000-4000-8000-000000000001'),'f1792000-0000-4000-8000-000000000001',0,'Counted mention','{f1791000-0000-4000-8000-000000000002}');
do $$ begin if public.taskfold_mentions_summary() is distinct from '{"total":0,"unread":0}'::jsonb then raise exception 'Sender counted another inbox';end if;end $$;
set local request.jwt.claim.sub='f1791000-0000-4000-8000-000000000002';
do $$ declare m public.task_mentions;begin
 if public.taskfold_mentions_summary() is distinct from '{"total":1,"unread":1}'::jsonb then raise exception 'Recipient count missing';end if;
 select * into strict m from public.task_mentions;
 perform public.taskfold_mark_mention(gen_random_uuid(),m.id,1,true);
 if public.taskfold_mentions_summary() is distinct from '{"total":1,"unread":0}'::jsonb then raise exception 'Read count wrong';end if;
end $$;
set local request.jwt.claim.sub='f1791000-0000-4000-8000-000000000003';
do $$ begin if public.taskfold_mentions_summary() is distinct from '{"total":0,"unread":0}'::jsonb then raise exception 'Outsider counted another inbox';end if;end $$;
set local request.jwt.claim.sub='f1791000-0000-4000-8000-000000000001';
delete from public.project_collaborators where project_id='f1792000-0000-4000-8000-000000000001' and user_id='f1791000-0000-4000-8000-000000000002';
set local request.jwt.claim.sub='f1791000-0000-4000-8000-000000000002';
do $$ begin if public.taskfold_mentions_summary() is distinct from '{"total":0,"unread":0}'::jsonb then raise exception 'Departed count leaked';end if;end $$;
set local request.jwt.claim.sub='';
do $$ begin begin perform public.taskfold_mentions_summary();raise exception 'Missing identity counted';exception when insufficient_privilege then null;end;end $$;
reset role;
do $$ begin
 if has_function_privilege('anon','public.taskfold_mentions_summary()','EXECUTE') or (select prosecdef from pg_proc where oid='public.taskfold_mentions_summary()'::regprocedure) then raise exception 'Unsafe summary grant';end if;
end $$;
rollback;
