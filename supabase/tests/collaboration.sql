-- Run inside a transaction/savepoint and ROLLBACK. No emails are sent.
insert into auth.users(id,email,raw_user_meta_data) values
 ('f01dcafe-0000-4000-8000-000000000001','taskfold-qa-owner@example.invalid','{}'),
 ('f01dcafe-0000-4000-8000-000000000002','taskfold-qa-member@example.invalid','{}'),
 ('f01dcafe-0000-4000-8000-000000000003','taskfold-qa-outsider@example.invalid','{}');
insert into public.profiles(id,user_id,display_name) select id,id,'Collaboration QA' from auth.users where id in ('f01dcafe-0000-4000-8000-000000000001','f01dcafe-0000-4000-8000-000000000002','f01dcafe-0000-4000-8000-000000000003') on conflict do nothing;
select set_config('request.jwt.claim.sub','f01dcafe-0000-4000-8000-000000000001',true);
set local role authenticated;
insert into public.projects(id,user_id,name) values ('f01dcafe-0000-4000-8000-000000000010',auth.uid(),'Collaboration transaction fixture');
insert into public.project_collaborators(id,project_id,invited_by,invited_email) values ('f01dcafe-0000-4000-8000-000000000020','f01dcafe-0000-4000-8000-000000000010',auth.uid(),'TASKFOLD-QA-MEMBER@example.invalid');
insert into public.tasks(id,user_id,title,project_id,subtasks) values ('f01dcafe-0000-4000-8000-000000000030',auth.uid(),'Initial','f01dcafe-0000-4000-8000-000000000010','[{"id":"child","title":"Child","completed":false,"subtasks":[{"id":"grand","title":"Grand","completed":false}]}]');
select set_config('request.jwt.claim.sub','f01dcafe-0000-4000-8000-000000000002',true);
do $$ begin
 if exists(select 1 from public.tasks where id='f01dcafe-0000-4000-8000-000000000030') then raise exception 'Pending invite exposed tasks'; end if;
end $$;
update public.project_collaborators set status='accepted' where id='f01dcafe-0000-4000-8000-000000000020';
do $$ declare n int; begin
 select count(*) into n from public.taskfold_project_members('f01dcafe-0000-4000-8000-000000000010');
 if n<>2 then raise exception 'Expected owner and accepted member, got %',n; end if;
 if not exists(select 1 from public.tasks where id='f01dcafe-0000-4000-8000-000000000030') then raise exception 'Accepted member cannot read'; end if;
end $$;
select public.taskfold_patch_task('f01dcafe-0000-4000-8000-000000000030','{"comments":[],"assigned_to":null}','{"comments":[{"id":"a","text":"First comment"}],"assigned_to":"f01dcafe-0000-4000-8000-000000000002"}');
select set_config('request.jwt.claim.sub','f01dcafe-0000-4000-8000-000000000001',true);
select public.taskfold_patch_task('f01dcafe-0000-4000-8000-000000000030','{"comments":[]}','{"comments":[{"id":"b","text":"Simultaneous comment"}]}');
-- Retry after a lost response must not duplicate a comment.
select public.taskfold_patch_task('f01dcafe-0000-4000-8000-000000000030','{"comments":[]}','{"comments":[{"id":"b","text":"Simultaneous comment"}]}');
select public.taskfold_patch_task('f01dcafe-0000-4000-8000-000000000030','{"subtasks":[{"id":"child","title":"Child","completed":false,"subtasks":[{"id":"grand","title":"Grand","completed":false}]}]}','{"subtasks":[{"id":"child","title":"Renamed child","completed":false,"subtasks":[{"id":"grand","title":"Grand","completed":false}]}]}');
select set_config('request.jwt.claim.sub','f01dcafe-0000-4000-8000-000000000002',true);
select public.taskfold_patch_task('f01dcafe-0000-4000-8000-000000000030','{"subtasks":[{"id":"child","title":"Child","completed":false,"subtasks":[{"id":"grand","title":"Grand","completed":false}]}]}','{"subtasks":[{"id":"child","title":"Child","completed":false,"subtasks":[{"id":"grand","title":"Grand","completed":true,"assigned_to":"f01dcafe-0000-4000-8000-000000000002"}]}]}');
do $$ declare t public.tasks; begin
 select * into t from public.tasks where id='f01dcafe-0000-4000-8000-000000000030';
 if jsonb_array_length(t.comments)<>2 or t.subtasks#>>'{0,title}'<>'Renamed child' or t.subtasks#>>'{0,subtasks,0,completed}'<>'true' then raise exception 'Concurrent edits lost data'; end if;
 begin
   perform public.taskfold_patch_task(t.id,'{"title":"Stale title"}','{"title":"Conflict"}');
   raise exception 'Expected conflict';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 begin
   update public.tasks set assigned_to='f01dcafe-0000-4000-8000-000000000003' where id=t.id;
   raise exception 'Expected assignment rejection';
 exception when others then if sqlerrm <> 'Assign tasks only to current project members' then raise; end if; end;
 begin
   update public.projects set user_id=auth.uid() where id='f01dcafe-0000-4000-8000-000000000010';
   raise exception 'Expected ownership rejection';
 exception when others then if sqlerrm <> 'Project ownership cannot be changed' then raise; end if; end;
end $$;
-- Outsider cannot read, patch, enumerate members, or assign themselves.
select set_config('request.jwt.claim.sub','f01dcafe-0000-4000-8000-000000000003',true);
do $$ begin
 if exists(select 1 from public.tasks where id='f01dcafe-0000-4000-8000-000000000030') or exists(select 1 from public.taskfold_project_members('f01dcafe-0000-4000-8000-000000000010')) then raise exception 'Outsider accessed shared data'; end if;
 begin
   perform public.taskfold_patch_task('f01dcafe-0000-4000-8000-000000000030','{"title":"Initial"}','{"title":"Unauthorized"}');
   raise exception 'Expected access rejection';
 exception when others then if sqlerrm not like 'This task is no longer available%' then raise; end if; end;
end $$;
-- Revocation also removes access to tasks the departing member created.
select set_config('request.jwt.claim.sub','f01dcafe-0000-4000-8000-000000000002',true);
insert into public.tasks(id,user_id,title,project_id) values ('f01dcafe-0000-4000-8000-000000000031',auth.uid(),'Member created','f01dcafe-0000-4000-8000-000000000010');
delete from public.project_collaborators where id='f01dcafe-0000-4000-8000-000000000020';
do $$ begin
 if exists(select 1 from public.tasks where id in ('f01dcafe-0000-4000-8000-000000000030','f01dcafe-0000-4000-8000-000000000031')) then raise exception 'Revoked member retained access'; end if;
end $$;
reset role;
-- Moving a task clears assignments that belonged to its previous project.
select set_config('request.jwt.claim.sub','f01dcafe-0000-4000-8000-000000000001',true);
set local role authenticated;
update public.tasks set assigned_to=auth.uid() where id='f01dcafe-0000-4000-8000-000000000030';
update public.tasks set project_id=null where id='f01dcafe-0000-4000-8000-000000000030';
do $$ begin
 if exists(select 1 from public.tasks where id='f01dcafe-0000-4000-8000-000000000030' and assigned_to is not null) then raise exception 'Move retained old assignment'; end if;
end $$;
-- Invitations sent before signup are linked only to the matching account.
insert into public.project_collaborators(id,project_id,invited_by,invited_email) values ('f01dcafe-0000-4000-8000-000000000021','f01dcafe-0000-4000-8000-000000000010',auth.uid(),'taskfold-qa-new@example.invalid');
reset role;
insert into auth.users(id,email,raw_user_meta_data) values ('f01dcafe-0000-4000-8000-000000000004','taskfold-qa-new@example.invalid','{}');
do $$ begin
 if not exists(select 1 from public.project_collaborators where id='f01dcafe-0000-4000-8000-000000000021' and user_id='f01dcafe-0000-4000-8000-000000000004') then raise exception 'Signup invitation not linked'; end if;
end $$;
