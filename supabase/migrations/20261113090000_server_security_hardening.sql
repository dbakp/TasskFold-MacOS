begin;

-- 1. Public object URLs (/storage/v1/object/public/avatars/...) are served for
-- public buckets without consulting RLS. The bucket-wide SELECT policy only
-- exposed listing/enumeration of every user's avatar path to any caller.
-- The clients upload to fresh UUID paths with a plain POST and read through the
-- public URL, so neither needs this policy. Owner-scoped INSERT/UPDATE/DELETE
-- policies are untouched.
drop policy if exists "Avatar images are publicly accessible" on storage.objects;

-- 2. Bucket limits. Avatars are images only. Task attachments keep every MIME
-- type (legacy clients do not restrict them) but gain a ceiling; the current
-- native clients already cap files at 5 MiB, so 25 MiB leaves legacy headroom.
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/png','image/jpeg','image/heic','image/webp','image/gif']
 where id = 'avatars';
update storage.buckets
   set file_size_limit = 26214400
 where id = 'task-attachments';

-- 3. Legacy tables are reachable only by signed-in users through RLS. The anon
-- role has no feature that needs them (no public share links; every policy keys
-- on auth.uid()), so remove all of its privileges. Nobody needs TRUNCATE (which
-- ignores RLS) or REFERENCES from the client role.
do $$
declare t text;
begin
  foreach t in array array['tasks','projects','sections','labels','profiles','project_collaborators'] loop
    if to_regclass('public.' || t) is not null then
      execute format('revoke all on table public.%I from anon', t);
      execute format('revoke truncate, references on table public.%I from authenticated', t);
    end if;
  end loop;
end $$;

-- Functions: the hosted ACLs grant EXECUTE to PUBLIC as well as anon, so both
-- must go for anon to lose access. Signed-in and service callers keep it.
do $$
declare f regprocedure;
begin
  foreach f in array array[
    to_regprocedure('public.get_project_collaborators_safe(uuid)'),
    to_regprocedure('public.get_current_user_email()'),
    to_regprocedure('public.handle_new_user()'),
    to_regprocedure('public.link_pending_invites()'),
    to_regprocedure('public.set_project_owner()')
  ] loop
    if f is not null then
      execute format('revoke execute on function %s from public, anon', f);
    end if;
  end loop;
  foreach f in array array[
    to_regprocedure('public.get_project_collaborators_safe(uuid)'),
    to_regprocedure('public.get_current_user_email()')
  ] loop
    if f is not null then
      execute format('grant execute on function %s to authenticated, service_role', f);
    end if;
  end loop;
end $$;

-- 4. pg_net's queue and response tables carry privileges for PUBLIC, which made
-- them writable by anon and authenticated (an HTTP request primitive). Remove
-- every client path and keep the roles that the in-database schedulers use.
do $$
declare t text; r text;
begin
  foreach t in array array['net.http_request_queue','net._http_response'] loop
    if to_regclass(t) is not null then
      execute format('revoke all on table %s from public, anon, authenticated', t);
      foreach r in array array['postgres','service_role','supabase_functions_admin'] loop
        if exists (select 1 from pg_roles where rolname = r) then
          execute format('grant select, insert, update, delete on table %s to %I', t, r);
        end if;
      end loop;
    end if;
  end loop;
  if to_regclass('net.http_request_queue_id_seq') is not null then
    revoke all on sequence net.http_request_queue_id_seq from public, anon, authenticated;
    foreach r in array array['postgres','service_role','supabase_functions_admin'] loop
      if exists (select 1 from pg_roles where rolname = r) then
        execute format('grant usage, select, update on sequence net.http_request_queue_id_seq to %I', r);
      end if;
    end loop;
  end if;
end $$;

-- 5. Invitations link to an Auth account only after its email is confirmed.
-- Otherwise someone could register an unconfirmed account with an invited
-- address and inherit that pending invitation. Linking runs on insert (for
-- providers and settings that confirm immediately) and when confirmation lands.
create or replace function public.link_pending_invites() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.email is null or new.email_confirmed_at is null then return new; end if;
  update public.project_collaborators set user_id = new.id
   where user_id is null and lower(invited_email) = lower(new.email);
  return new;
end $$;

create or replace function taskfold_private.link_account_invitations() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.email is null or new.email_confirmed_at is null then return new; end if;
  -- The invitation guard permits linking only when invoked by this auth.users trigger.
  update public.project_collaborators set user_id = new.id
   where user_id is null and lower(invited_email) = lower(new.email);
  return new;
end $$;

drop trigger if exists on_auth_user_confirmed_link_invites on auth.users;
create trigger on_auth_user_confirmed_link_invites
  after update of email_confirmed_at on auth.users
  for each row when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function public.link_pending_invites();
drop trigger if exists taskfold_confirmed_link_account_invitations on auth.users;
create trigger taskfold_confirmed_link_account_invitations
  after update of email_confirmed_at on auth.users
  for each row when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function taskfold_private.link_account_invitations();

-- Existing pending invitations for accounts that are confirmed but were never
-- linked are intentionally left alone; this migration changes behaviour going forward.

-- 6. Account removal: cancel a pending (not yet completed) removal. Receipts are
-- now minted only by the execute call, so cancel exists to release the upload
-- fence after an interrupted removal. It deletes no data and never touches a
-- completed receipt.
create or replace function public.taskfold_account_removal_cancel(_account uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare gone integer;
begin
  if _account is null then raise exception 'Invalid removal cancellation' using errcode = '22023'; end if;
  if exists (select 1 from taskfold_private.account_removal_receipts
              where account_id = _account and completed_at is not null) then
    return jsonb_build_object('canceled', 0, 'complete', true);
  end if;
  -- Serialize with taskfold_account_removal_begin, which locks the same row.
  perform 1 from auth.users where id = _account for update;
  delete from taskfold_private.account_removal_receipts
   where account_id = _account and completed_at is null;
  get diagnostics gone = row_count;
  return jsonb_build_object('canceled', gone, 'complete', false);
end $$;
revoke all on function public.taskfold_account_removal_cancel(uuid) from public, anon, authenticated;
grant execute on function public.taskfold_account_removal_cancel(uuid) to service_role;

commit;
