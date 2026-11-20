-- Server hardening checks. One rolled-back transaction, reserved synthetic UUIDs
-- and example.invalid addresses only. Runs on the full hosted schema (after the
-- migration) as postgres, and on the PGlite harness in Scripts/Database.
begin;
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$begin if ok is distinct from true then raise exception 'Assertion failed: %',label;end if;end$$;

-- Storage: the bucket-wide read policy is gone, limits are in place.
select pg_temp.require(not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='Avatar images are publicly accessible'),'avatar listing policy dropped');
select pg_temp.require((select public and file_size_limit=5242880 and allowed_mime_types@>array['image/png','image/jpeg','image/heic','image/webp','image/gif'] and allowed_mime_types<@array['image/png','image/jpeg','image/heic','image/webp','image/gif'] from storage.buckets where id='avatars'),'avatar bucket limits');
select pg_temp.require((select file_size_limit=26214400 and allowed_mime_types is null and not public from storage.buckets where id='task-attachments'),'attachment bucket limit without MIME restriction');

-- Legacy tables: anon has nothing; authenticated keeps DML but not TRUNCATE/REFERENCES.
do $$declare t text;p text;begin
 foreach t in array array['tasks','projects','sections','labels','profiles','project_collaborators'] loop
  foreach p in array array['select','insert','update','delete','truncate','references','trigger'] loop
   perform pg_temp.require(not has_table_privilege('anon','public.'||t,p),'anon '||p||' on '||t);
  end loop;
  perform pg_temp.require(not has_table_privilege('authenticated','public.'||t,'truncate'),'authenticated truncate on '||t);
  perform pg_temp.require(not has_table_privilege('authenticated','public.'||t,'references'),'authenticated references on '||t);
  perform pg_temp.require(has_table_privilege('authenticated','public.'||t,'select'),'authenticated still reads '||t);
  perform pg_temp.require(has_table_privilege('authenticated','public.'||t,'insert'),'authenticated still writes '||t);
 end loop;
end$$;

-- Functions.
do $$declare f text;begin
 foreach f in array array['public.get_project_collaborators_safe(uuid)','public.get_current_user_email()','public.handle_new_user()','public.link_pending_invites()','public.set_project_owner()'] loop
  perform pg_temp.require(not has_function_privilege('anon',f,'execute'),'anon execute on '||f);
 end loop;
 foreach f in array array['public.get_project_collaborators_safe(uuid)','public.get_current_user_email()'] loop
  perform pg_temp.require(has_function_privilege('authenticated',f,'execute') and has_function_privilege('service_role',f,'execute'),'signed-in execute kept on '||f);
 end loop;
 perform pg_temp.require(not has_function_privilege('anon','public.taskfold_account_removal_cancel(uuid)','execute') and not has_function_privilege('authenticated','public.taskfold_account_removal_cancel(uuid)','execute') and has_function_privilege('service_role','public.taskfold_account_removal_cancel(uuid)','execute'),'cancel is service-only');
end$$;

-- pg_net tables.
do $$declare t text;p text;begin
 foreach t in array array['net.http_request_queue','net._http_response'] loop
  if to_regclass(t) is null then continue; end if;
  foreach p in array array['select','insert','update','delete','truncate','references','trigger'] loop
   perform pg_temp.require(not has_table_privilege('anon',t,p) and not has_table_privilege('authenticated',t,p),p||' on '||t||' closed to client roles');
  end loop;
 end loop;
 if to_regclass('net.http_request_queue') is not null then
  perform pg_temp.require(not has_sequence_privilege('anon','net.http_request_queue_id_seq','usage') and not has_sequence_privilege('authenticated','net.http_request_queue_id_seq','usage'),'queue sequence closed');
  perform pg_temp.require(has_table_privilege('service_role','net.http_request_queue','insert'),'service role keeps the queue');
 end if;
end$$;

-- Invitations link only after confirmation.
insert into auth.users(id,email,email_confirmed_at) values('f0a0cafe-0000-4000-8000-000000000001','taskfold-hardening-owner@example.invalid',now());
insert into public.profiles(user_id) values('f0a0cafe-0000-4000-8000-000000000001') on conflict do nothing;
insert into public.projects(id,user_id,name) values('f0a0cafe-0000-4000-8000-000000000010','f0a0cafe-0000-4000-8000-000000000001','Hardening project');
set local request.jwt.claim.sub='f0a0cafe-0000-4000-8000-000000000001';
insert into public.project_collaborators(id,project_id,invited_email,invited_by) values
 ('f0a0cafe-0000-4000-8000-000000000021','f0a0cafe-0000-4000-8000-000000000010','taskfold-hardening-late@example.invalid','f0a0cafe-0000-4000-8000-000000000001'),
 ('f0a0cafe-0000-4000-8000-000000000022','f0a0cafe-0000-4000-8000-000000000010','taskfold-hardening-now@example.invalid','f0a0cafe-0000-4000-8000-000000000001');
set local request.jwt.claim.sub='';
-- Unconfirmed registration with the invited address must not inherit the invitation.
insert into auth.users(id,email,email_confirmed_at) values('f0a0cafe-0000-4000-8000-000000000002','Taskfold-Hardening-Late@example.invalid',null);
select pg_temp.require((select user_id is null from public.project_collaborators where id='f0a0cafe-0000-4000-8000-000000000021'),'unconfirmed signup did not link');
-- Unrelated updates keep it unlinked.
update auth.users set email='taskfold-hardening-late@example.invalid' where id='f0a0cafe-0000-4000-8000-000000000002';
select pg_temp.require((select user_id is null from public.project_collaborators where id='f0a0cafe-0000-4000-8000-000000000021'),'non-confirmation update did not link');
-- Confirmation links it (case-insensitively).
update auth.users set email_confirmed_at=now() where id='f0a0cafe-0000-4000-8000-000000000002';
select pg_temp.require((select user_id='f0a0cafe-0000-4000-8000-000000000002' from public.project_collaborators where id='f0a0cafe-0000-4000-8000-000000000021'),'confirmation linked the invitation');
-- Immediately confirmed signups (current behaviour) still link on insert.
insert into auth.users(id,email,email_confirmed_at) values('f0a0cafe-0000-4000-8000-000000000003','taskfold-hardening-now@example.invalid',now());
select pg_temp.require((select user_id='f0a0cafe-0000-4000-8000-000000000003' from public.project_collaborators where id='f0a0cafe-0000-4000-8000-000000000022'),'confirmed signup links on insert');
-- Re-confirming does not rewrite a linked invitation.
update auth.users set email_confirmed_at=null where id='f0a0cafe-0000-4000-8000-000000000003';
update auth.users set email_confirmed_at=now() where id='f0a0cafe-0000-4000-8000-000000000003';
select pg_temp.require((select user_id='f0a0cafe-0000-4000-8000-000000000003' from public.project_collaborators where id='f0a0cafe-0000-4000-8000-000000000022'),'relinking is stable');

-- Removal cancellation: pending receipts are cleared, completed ones are not.
insert into taskfold_private.account_removal_receipts(token_hash,account_id) values(repeat('a',64),'f0a0cafe-0000-4000-8000-000000000001');
select pg_temp.require((select (public.taskfold_account_removal_cancel('f0a0cafe-0000-4000-8000-000000000001')->>'canceled')::int=1),'pending receipt canceled');
select pg_temp.require(not exists(select 1 from taskfold_private.account_removal_receipts where account_id='f0a0cafe-0000-4000-8000-000000000001'),'receipt gone');
select pg_temp.require((select public.taskfold_account_removal_cancel('f0a0cafe-0000-4000-8000-000000000001')->>'canceled')='0','cancel is idempotent');
insert into taskfold_private.account_removal_receipts(token_hash,account_id,completed_at) values(repeat('b',64),'f0a0cafe-0000-4000-8000-000000000001',now());
select pg_temp.require((public.taskfold_account_removal_cancel('f0a0cafe-0000-4000-8000-000000000001')->>'complete')::boolean,'completed removal reported');
select pg_temp.require(exists(select 1 from taskfold_private.account_removal_receipts where token_hash=repeat('b',64)),'completed receipt untouched');
rollback;
