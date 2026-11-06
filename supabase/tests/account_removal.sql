-- Reserved synthetic identities and one rolled-back transaction only.
begin;
insert into auth.users(id,email) values
 ('f084cafe-0000-4000-8000-000000000001','taskfold-removal-a@example.invalid'),
 ('f084cafe-0000-4000-8000-000000000002','taskfold-removal-b@example.invalid'),
 ('f084cafe-0000-4000-8000-000000000003','taskfold-removal-c@example.invalid');
insert into public.profiles(user_id) values('f084cafe-0000-4000-8000-000000000001'),('f084cafe-0000-4000-8000-000000000002'),('f084cafe-0000-4000-8000-000000000003') on conflict do nothing;
insert into auth.sessions(id,user_id) values('f084cafe-0000-4000-8000-000000000010','f084cafe-0000-4000-8000-000000000001');
insert into public.projects(id,user_id,name) values('f084cafe-0000-4000-8000-000000000020','f084cafe-0000-4000-8000-000000000001','Departing project');
set local request.jwt.claim.sub='f084cafe-0000-4000-8000-000000000001';
insert into public.project_collaborators(id,project_id,invited_email,invited_by) values
 ('f084cafe-0000-4000-8000-000000000021','f084cafe-0000-4000-8000-000000000020','taskfold-removal-c@example.invalid','f084cafe-0000-4000-8000-000000000001');
-- An administrative historical ownership transfer: deleting the old inviter must preserve C's membership.
update public.projects set user_id='f084cafe-0000-4000-8000-000000000002' where id='f084cafe-0000-4000-8000-000000000020';
update public.project_collaborators set status='accepted' where id='f084cafe-0000-4000-8000-000000000021';
do $$ begin
 begin update public.project_collaborators set invited_by=null where id='f084cafe-0000-4000-8000-000000000021'; raise exception 'Invoker cleared inviter';
 exception when others then if sqlerrm<>'Invitation details cannot be changed' then raise; end if; end;
end $$;
set local request.jwt.claim.sub='';
insert into public.tasks(id,user_id,title) values('f084cafe-0000-4000-8000-000000000030','f084cafe-0000-4000-8000-000000000001','Departing root');
insert into public.tasks(id,user_id,title,recurrence_parent_id,project_id) values
 ('f084cafe-0000-4000-8000-000000000031','f084cafe-0000-4000-8000-000000000002','Surviving work','f084cafe-0000-4000-8000-000000000030','f084cafe-0000-4000-8000-000000000020');
insert into taskfold_private.reminder_devices(id,user_id) values('f084cafe-0000-4000-8000-000000000040','f084cafe-0000-4000-8000-000000000001');
set local role authenticated;
do $$ begin
 begin perform public.taskfold_account_removal_status(repeat('a',64)); raise exception 'Client read receipt'; exception when insufficient_privilege then null; end;
 begin perform public.taskfold_account_removal_begin('f084cafe-0000-4000-8000-000000000001','f084cafe-0000-4000-8000-000000000010',repeat('a',64)); raise exception 'Client granted removal'; exception when insufficient_privilege then null; end;
end $$;
reset role;
-- A live account can upload before authorization begins.
set local request.jwt.claim.sub='f084cafe-0000-4000-8000-000000000001';
set local role authenticated;
insert into storage.objects(bucket_id,name,owner_id) values('avatars','f084cafe-0000-4000-8000-000000000001/before.jpg','f084cafe-0000-4000-8000-000000000001');
reset role;
delete from storage.objects where name='f084cafe-0000-4000-8000-000000000001/before.jpg';
-- Every administrative RPC and the receipt table reject both client roles.
do $$ declare item regprocedure; begin
 for item in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'taskfold_account_removal_%' loop
  if has_function_privilege('anon',item,'execute') or has_function_privilege('authenticated',item,'execute') then raise exception 'Client can call privileged removal function: %',item; end if;
 end loop;
 if has_table_privilege('anon','taskfold_private.account_removal_receipts','select')
 or has_table_privilege('authenticated','taskfold_private.account_removal_receipts','select') then raise exception 'Receipt table is exposed'; end if;
 if has_function_privilege('anon','public.taskfold_account_allows_storage_write()','execute') then raise exception 'Anonymous storage predicate execution'; end if;
end $$;
-- Expired and banned sessions cannot create a new irreversible command.
update auth.sessions set not_after=clock_timestamp()-interval '1 minute' where id='f084cafe-0000-4000-8000-000000000010';
do $$ begin
 begin perform public.taskfold_account_removal_begin('f084cafe-0000-4000-8000-000000000001','f084cafe-0000-4000-8000-000000000010',repeat('a',64)); raise exception 'Expired session accepted'; exception when invalid_authorization_specification then null; end;
end $$;
update auth.sessions set not_after=null where id='f084cafe-0000-4000-8000-000000000010';
update auth.users set banned_until=clock_timestamp()+interval '1 hour' where id='f084cafe-0000-4000-8000-000000000001';
do $$ begin
 begin perform public.taskfold_account_removal_begin('f084cafe-0000-4000-8000-000000000001','f084cafe-0000-4000-8000-000000000010',repeat('a',64)); raise exception 'Banned session accepted'; exception when invalid_authorization_specification then null; end;
end $$;
update auth.users set banned_until=null where id='f084cafe-0000-4000-8000-000000000001';
set local role service_role;
do $$ begin
 begin perform public.taskfold_account_removal_begin('f084cafe-0000-4000-8000-000000000002','f084cafe-0000-4000-8000-000000000010',repeat('b',64)); raise exception 'Foreign session accepted'; exception when invalid_authorization_specification then null; end;
 perform public.taskfold_account_removal_begin('f084cafe-0000-4000-8000-000000000001','f084cafe-0000-4000-8000-000000000010',repeat('a',64));
 if public.taskfold_account_removal_status(repeat('a',64))->>'complete'<>'false' then raise exception 'Pending receipt completed early'; end if;
end $$;
reset role;
-- The same valid JWT must no longer upload after a deletion is authorized.
set local role authenticated;
do $$ begin
 begin
  insert into storage.objects(bucket_id,name,owner_id) values('avatars','f084cafe-0000-4000-8000-000000000001/late.jpg','f084cafe-0000-4000-8000-000000000001');
  raise exception 'Pending removal permitted upload';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Another live account retains normal writes.
set local request.jwt.claim.sub='f084cafe-0000-4000-8000-000000000002';
set local role authenticated;
insert into storage.objects(bucket_id,name,owner_id) values('avatars','f084cafe-0000-4000-8000-000000000002/temp.jpg','f084cafe-0000-4000-8000-000000000002');
reset role;
delete from storage.objects where name='f084cafe-0000-4000-8000-000000000002/temp.jpg';
set local request.jwt.claim.sub='';
insert into storage.objects(bucket_id,name,owner_id) values('avatars','f084cafe-0000-4000-8000-000000000001/avatar.jpg','f084cafe-0000-4000-8000-000000000001'),('avatars','f084cafe-0000-4000-8000-000000000002/avatar.jpg','f084cafe-0000-4000-8000-000000000002');
insert into storage.objects(bucket_id,name,owner_id) values('avatars','f084cafe-0000-4000-8000-000000000001/other-owner.jpg','f084cafe-0000-4000-8000-000000000002');
insert into storage.objects(bucket_id,name) values('task-attachments','f084cafe-0000-4000-8000-000000000001/legacy.jpg');
-- A stale authenticated token cannot overwrite a surviving object either.
set local request.jwt.claim.sub='f084cafe-0000-4000-8000-000000000001';
set local role authenticated;
do $$ declare changed integer; begin
 update storage.objects set name='f084cafe-0000-4000-8000-000000000001/replaced.jpg'
 where name='f084cafe-0000-4000-8000-000000000001/avatar.jpg';
 get diagnostics changed=row_count;
 if changed<>0 then raise exception 'Pending removal permitted overwrite'; end if;
end $$;
reset role;
set local request.jwt.claim.sub='';
do $$ begin
 if jsonb_array_length(public.taskfold_account_removal_files(repeat('a',64)))<>2 then raise exception 'Manifest owner/prefix boundary failed'; end if;
 begin perform public.taskfold_account_removal_prepare(repeat('a',64)); raise exception 'Prepared with files'; exception when others then if sqlerrm<>'Remove stored files before the account' then raise; end if; end;
 -- Local SQL simulates successful Storage API removal; production must use the Storage API.
 delete from storage.objects where owner_id='f084cafe-0000-4000-8000-000000000001' or name='f084cafe-0000-4000-8000-000000000001/legacy.jpg';
 perform public.taskfold_account_removal_prepare(repeat('a',64));
 if exists(select 1 from public.tasks where id='f084cafe-0000-4000-8000-000000000031' and recurrence_parent_id is not null) then raise exception 'Foreign recurrence still cascades'; end if;
 begin perform public.taskfold_account_removal_complete(repeat('a',64)); raise exception 'Completed live account'; exception when others then if sqlerrm<>'Account removal is not complete' then raise; end if; end;
end $$;
delete from auth.users where id='f084cafe-0000-4000-8000-000000000001';
set local role service_role;
select public.taskfold_account_removal_complete(repeat('a',64));
select public.taskfold_account_removal_complete(repeat('a',64));
do $$ begin
 if public.taskfold_account_removal_status(repeat('a',64))->>'complete'<>'true' then raise exception 'Lost-response receipt unavailable'; end if;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.tasks where id='f084cafe-0000-4000-8000-000000000031' and title='Surviving work') then raise exception 'Other account work removed'; end if;
 if not exists(select 1 from public.project_collaborators where id='f084cafe-0000-4000-8000-000000000021' and invited_by is null and status='accepted') then raise exception 'Other membership removed'; end if;
 if (select count(*) from storage.objects)<>2 then raise exception 'Other storage removed'; end if;
 if exists(select 1 from taskfold_private.reminder_devices where user_id is null) then raise exception 'Orphaned push device remains'; end if;
end $$;
-- Completed removal cannot recreate files through the unexpired old JWT,
-- even after its short-lived retry receipt is purged.
delete from taskfold_private.account_removal_receipts;
set local request.jwt.claim.sub='f084cafe-0000-4000-8000-000000000001';
set local role authenticated;
do $$ begin
 begin
  insert into storage.objects(bucket_id,name,owner_id) values('avatars','f084cafe-0000-4000-8000-000000000001/recreated.jpg','f084cafe-0000-4000-8000-000000000001');
  raise exception 'Removed account permitted upload';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
