-- Global, service-only signing material; no per-account personal data is kept.
create table taskfold_private.account_removal_proof_keys (
 id uuid primary key default gen_random_uuid(),
 secret bytea not null check(octet_length(secret)=32),
 active boolean not null default true,
 created_at timestamptz not null default clock_timestamp(),
 revoked_at timestamptz
);
create unique index account_removal_proof_one_active on taskfold_private.account_removal_proof_keys(active)
 where active and revoked_at is null;
alter table taskfold_private.account_removal_proof_keys enable row level security;
revoke all on taskfold_private.account_removal_proof_keys from public,anon,authenticated;
grant usage on schema taskfold_private to service_role;
grant select on taskfold_private.account_removal_proof_keys to service_role;
insert into taskfold_private.account_removal_proof_keys(secret) values(extensions.gen_random_bytes(32));

-- Old inactive keys must remain available for status-only proofs unless revoked.
create function taskfold_private.account_removal_proof_key(_id uuid) returns jsonb
language sql security definer set search_path='' as $$
 select jsonb_build_object('id',id,'key',encode(secret,'base64'))
 from taskfold_private.account_removal_proof_keys
 where revoked_at is null and ((_id is null and active) or id=_id)
 limit 1
$$;
revoke all on function taskfold_private.account_removal_proof_key(uuid) from public,anon,authenticated;
grant execute on function taskfold_private.account_removal_proof_key(uuid) to service_role;
create function public.taskfold_account_removal_proof_key(_id uuid default null) returns jsonb
language sql security invoker set search_path='' as $$select taskfold_private.account_removal_proof_key(_id)$$;
revoke all on function public.taskfold_account_removal_proof_key(uuid) from public,anon,authenticated;
grant execute on function public.taskfold_account_removal_proof_key(uuid) to service_role;

-- Only the Edge Function may ask this after verifying a status-only proof.
-- A signed proof alone can never delete or change rows/files, or confirm a
-- still-existing account. Canonical file ownership wins over legacy prefixes.
create function taskfold_private.account_removal_absent(_account uuid) returns boolean
language sql security definer set search_path='' as $$
 select _account is not null
 and not exists(select 1 from auth.users where id=_account)
 and not exists(select 1 from storage.objects o where coalesce(o.owner_id,o.owner::text)=_account::text
  or (o.owner_id is null and o.owner is null and o.bucket_id in ('avatars','task-attachments')
      and starts_with(o.name,_account::text||'/')))
$$;
revoke all on function taskfold_private.account_removal_absent(uuid) from public,anon,authenticated;
grant execute on function taskfold_private.account_removal_absent(uuid) to service_role;
create function public.taskfold_account_removal_absent(_account uuid) returns boolean
language sql security invoker set search_path='' as $$select taskfold_private.account_removal_absent(_account)$$;
revoke all on function public.taskfold_account_removal_absent(uuid) from public,anon,authenticated;
grant execute on function public.taskfold_account_removal_absent(uuid) to service_role;
