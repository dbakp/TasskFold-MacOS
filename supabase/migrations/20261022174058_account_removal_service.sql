-- Server-only authorization and retry receipts. No task/profile/file content is retained.
create table if not exists taskfold_private.account_removal_receipts (
 token_hash text primary key check(token_hash ~ '^[0-9a-f]{64}$'),
 account_id uuid not null,
 created_at timestamptz not null default clock_timestamp(),
 completed_at timestamptz
);
create index if not exists account_removal_receipts_account on taskfold_private.account_removal_receipts(account_id);
create index if not exists account_removal_receipts_expiry on taskfold_private.account_removal_receipts(created_at);
alter table taskfold_private.account_removal_receipts enable row level security;
revoke all on taskfold_private.account_removal_receipts from public,anon,authenticated;
grant select,insert,update,delete on taskfold_private.account_removal_receipts to service_role;

-- Old access JWTs survive Auth removal until expiry. Restrictive write policies
-- prevent files from being recreated after cleanup, including during a pending
-- removal. Existing bucket/prefix policies still decide normal access.
create or replace function public.taskfold_account_allows_storage_write() returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare caller uuid:=auth.uid();
begin
 -- Pair the upload transaction's key-share lock with begin's exclusive user
 -- lock. Authorization waits for uploads already in flight; subsequent writes
 -- take a fresh PL/pgSQL snapshot after the receipt has committed.
 perform 1 from auth.users where id=caller for key share;
 if not found then return false; end if;
 return not exists(select 1 from taskfold_private.account_removal_receipts
  where account_id=caller and created_at>statement_timestamp()-interval '7 days');
end $$;
revoke all on function public.taskfold_account_allows_storage_write() from public,anon;
grant execute on function public.taskfold_account_allows_storage_write() to authenticated,service_role;
create policy taskfold_account_removal_blocks_upload on storage.objects as restrictive
 for insert to authenticated with check((select public.taskfold_account_allows_storage_write()));
create policy taskfold_account_removal_blocks_update on storage.objects as restrictive
 for update to authenticated using((select public.taskfold_account_allows_storage_write()))
 with check((select public.taskfold_account_allows_storage_write()));

-- An inviter's removal must not delete another member's access to a surviving project.
alter table public.project_collaborators alter column invited_by drop not null;
alter table public.project_collaborators drop constraint if exists project_collaborators_invited_by_fkey;
alter table public.project_collaborators drop constraint if exists project_collaborators_invited_by_profile_fkey;
alter table public.project_collaborators add constraint project_collaborators_invited_by_fkey
 foreign key(invited_by) references auth.users(id) on delete set null;
alter table public.project_collaborators add constraint project_collaborators_invited_by_profile_fkey
 foreign key(invited_by) references public.profiles(user_id) on delete set null;

-- Both inviter constraints share this prefix; membership cleanup uses user_id.
create index if not exists taskfold_project_collaborators_inviter on public.project_collaborators(invited_by);
create index if not exists taskfold_project_collaborators_member on public.project_collaborators(user_id);

create or replace function taskfold_private.prepare_invitation() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and pg_trigger_depth()>1 then
  if old.user_id is null and new.user_id is not null
   and (to_jsonb(new)-'user_id')=(to_jsonb(old)-'user_id')
   and exists(select 1 from auth.users where id=new.user_id and lower(email)=lower(new.invited_email)) then return new; end if;
  if old.invited_by is not null and new.invited_by is null
   and (to_jsonb(new)-'invited_by')=(to_jsonb(old)-'invited_by')
   and (not exists(select 1 from auth.users where id=old.invited_by)
        or not exists(select 1 from public.profiles where user_id=old.invited_by)) then return new; end if;
 end if;
 if auth.uid() is null then raise exception 'Sign in to manage invitations'; end if;
 if tg_op='INSERT' then
  if not public.is_project_owner(auth.uid(),new.project_id) or new.invited_by is distinct from auth.uid()
   or new.role is distinct from 'collaborator' or new.status is distinct from 'pending' then
   raise exception 'Only the project owner can invite collaborators'; end if;
  new.invited_email:=lower(trim(new.invited_email));
  select id into new.user_id from auth.users where lower(email)=new.invited_email;
  if new.user_id=auth.uid() then raise exception 'You already own this project'; end if;
 else
  if new.project_id is distinct from old.project_id or new.invited_by is distinct from old.invited_by
   or new.role is distinct from old.role or new.invited_email is distinct from old.invited_email
   or new.user_id is distinct from old.user_id then raise exception 'Invitation details cannot be changed'; end if;
  if new.status='accepted' and old.status<>'accepted' then new.accepted_at:=now(); end if;
 end if;
 return new;
end $$;

create or replace function public.taskfold_account_removal_status(_token_hash text) returns jsonb
language sql security definer set search_path='' as $$
 select jsonb_build_object('account',account_id,'complete',completed_at is not null)
 from taskfold_private.account_removal_receipts
 where token_hash=_token_hash and created_at>clock_timestamp()-interval '7 days'
$$;
create or replace function public.taskfold_account_removal_begin(_account uuid,_session uuid,_token_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if _token_hash is null or _token_hash !~ '^[0-9a-f]{64}$' then raise exception 'Invalid removal authorization' using errcode='22023'; end if;
 perform 1 from auth.sessions s join auth.users u on u.id=s.user_id
 where s.id=_session and s.user_id=_account and (s.not_after is null or s.not_after>clock_timestamp())
 and (u.banned_until is null or u.banned_until<=clock_timestamp()) for update of u for key share of s;
 if not found then raise exception 'Sign in again to remove your account' using errcode='28000'; end if;
 delete from taskfold_private.account_removal_receipts where created_at<=clock_timestamp()-interval '7 days';
 if (select count(*) from taskfold_private.account_removal_receipts where account_id=_account)>=64
 and not exists(select 1 from taskfold_private.account_removal_receipts where token_hash=_token_hash) then
  raise exception 'Retry with an existing removal request' using errcode='54000'; end if;
 insert into taskfold_private.account_removal_receipts(token_hash,account_id) values(_token_hash,_account) on conflict do nothing;
 if not exists(select 1 from taskfold_private.account_removal_receipts where token_hash=_token_hash and account_id=_account) then
  raise exception 'Invalid removal authorization' using errcode='28000'; end if;
 return public.taskfold_account_removal_status(_token_hash);
end $$;

create or replace function public.taskfold_account_removal_files(_token_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_owner uuid; result jsonb;
begin
 select account_id into v_owner from taskfold_private.account_removal_receipts
 where token_hash=_token_hash and created_at>clock_timestamp()-interval '7 days' and completed_at is null;
 if not found then raise exception 'Removal authorization unavailable' using errcode='28000'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('bucket',f.bucket_id,'name',f.name)),'[]') into result from (
  select o.bucket_id,o.name from storage.objects o
  where coalesce(o.owner_id,o.owner::text)=v_owner::text
   or (o.owner_id is null and o.owner is null and o.bucket_id in ('avatars','task-attachments')
       and starts_with(o.name,v_owner::text||'/'))
  order by o.bucket_id,o.name limit 100
 ) f;
 return result;
end $$;

create or replace function public.taskfold_account_removal_prepare(_token_hash text) returns uuid
language plpgsql security definer set search_path='' as $$
declare departing uuid;
begin
 select account_id into departing from taskfold_private.account_removal_receipts
 where token_hash=_token_hash and created_at>clock_timestamp()-interval '7 days' and completed_at is null;
 if not found then raise exception 'Removal authorization unavailable' using errcode='28000'; end if;
 if jsonb_array_length(public.taskfold_account_removal_files(_token_hash))<>0 then raise exception 'Remove stored files before the account'; end if;
 -- A surviving task must not cascade away merely because its recurrence parent leaves.
 update public.tasks child set recurrence_parent_id=null where child.user_id<>departing
 and child.recurrence_parent_id in(select id from public.tasks where user_id=departing);
 -- Device rows otherwise retain a push token with a NULL owner after Auth deletion.
 delete from taskfold_private.reminder_devices where user_id=departing;
 return departing;
end $$;

create or replace function public.taskfold_account_removal_complete(_token_hash text) returns boolean
language plpgsql security definer set search_path='' as $$
declare departing uuid; done timestamptz;
begin
 select account_id,completed_at into departing,done from taskfold_private.account_removal_receipts
 where token_hash=_token_hash and created_at>clock_timestamp()-interval '7 days';
 if not found then raise exception 'Removal authorization unavailable' using errcode='28000'; end if;
 if done is not null then return true; end if;
 if exists(select 1 from auth.users where id=departing)
 or jsonb_array_length(public.taskfold_account_removal_files(_token_hash))<>0 then raise exception 'Account removal is not complete'; end if;
 update taskfold_private.account_removal_receipts set completed_at=coalesce(completed_at,clock_timestamp()) where account_id=departing;
 return true;
end $$;
revoke all on function public.taskfold_account_removal_status(text),public.taskfold_account_removal_begin(uuid,uuid,text),
 public.taskfold_account_removal_files(text),public.taskfold_account_removal_prepare(text),public.taskfold_account_removal_complete(text) from public,anon,authenticated;
grant execute on function public.taskfold_account_removal_status(text),public.taskfold_account_removal_begin(uuid,uuid,text),
 public.taskfold_account_removal_files(text),public.taskfold_account_removal_prepare(text),public.taskfold_account_removal_complete(text) to service_role;
-- Receipt expiry also runs opportunistically at begin; no task/user content is retained.
do $$ begin
 if exists(select 1 from pg_extension where extname='pg_cron') then
  perform cron.schedule('taskfold-account-removal-receipts','11 * * * *',
   $job$delete from taskfold_private.account_removal_receipts where created_at<=clock_timestamp()-interval '7 days'$job$);
 end if;
end $$;
