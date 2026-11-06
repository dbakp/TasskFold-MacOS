-- A cancelled, not-yet-created enrollment must never become an active key on a
-- delayed retry. These owner-scoped tombstones contain no text, hash or secret.
create table taskfold_private.automation_key_cancellations (
 user_id uuid not null references auth.users(id) on delete cascade,
 id uuid not null check(id<>'00000000-0000-0000-0000-000000000000'),
 cancelled_at timestamptz not null default clock_timestamp(),
 primary key(user_id,id)
);
create index automation_key_cancellations_owner_date on taskfold_private.automation_key_cancellations(user_id,cancelled_at desc,id);
alter table taskfold_private.automation_key_cancellations enable row level security;
revoke all on taskfold_private.automation_key_cancellations from public,anon,authenticated,service_role;

create function taskfold_private.automation_refuse_cancelled_key() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 -- All supported management paths take this same account mutex. Retain it here
 -- as well so a later privileged insert cannot race a cancellation check.
 perform pg_advisory_xact_lock(hashtextextended('automation:'||new.user_id::text,11819));
 if exists(select 1 from taskfold_private.automation_key_cancellations where user_id=new.user_id and id=new.id) then
  raise exception using errcode='PT409',message='Key setup was discarded';
 end if;
 return new;
end$$;
revoke all on function taskfold_private.automation_refuse_cancelled_key() from public,anon,authenticated,service_role;
create trigger automation_refuse_cancelled_key before insert on taskfold_private.automation_keys
 for each row execute function taskfold_private.automation_refuse_cancelled_key();

create function taskfold_private.automation_cancel_key(_account uuid,_session uuid,_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare now_at timestamptz; existing taskfold_private.automation_keys;
begin
 perform taskfold_private.automation_account_lock(_account);
 perform 1 from auth.sessions where id=_session and user_id=_account and (not_after is null or not_after>clock_timestamp()) for key share;
 if not found then raise exception using errcode='28000',message='Sign in again';end if;
 if _id is null or _id='00000000-0000-0000-0000-000000000000' then raise exception using errcode='22023',message='Invalid key setup';end if;
 now_at=clock_timestamp();
 select * into existing from taskfold_private.automation_keys where id=_id and user_id=_account for update;
 if found then
  -- Existing immutable key rows already prevent recreation/renewal. Revoking
  -- owned keys is never subject to the new tombstone issuance budget.
  update taskfold_private.automation_keys set revoked_at=coalesce(revoked_at,now_at) where id=_id and user_id=_account;
 elsif not exists(select 1 from taskfold_private.automation_key_cancellations where user_id=_account and id=_id) then
  -- Bound permanent history independently of the 10-key creation budget.
  -- Existing cancellation retries are always free of this new-row limit.
  if (select count(*) from taskfold_private.automation_key_cancellations where user_id=_account and cancelled_at>=date_trunc('day',now_at at time zone 'UTC') at time zone 'UTC')>=100 then
   raise exception using errcode='PT429',message='Key setup cancellation limit reached';
  end if;
  insert into taskfold_private.automation_key_cancellations(user_id,id,cancelled_at) values(_account,_id,now_at);
 end if;
 -- A foreign key ID has the same response as an unknown ID; no foreign key
 -- metadata, state or table row is disclosed or changed. Only this account's
 -- future enrollment is cancelled, regardless of another account's ID choice.
 return jsonb_build_object('account',_account,'id',_id,'cancelled',true);
end$$;
revoke all on function taskfold_private.automation_cancel_key(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function taskfold_private.automation_cancel_key(uuid,uuid,uuid) to service_role;
create function public.taskfold_automation_cancel_key(_account uuid,_session uuid,_id uuid) returns jsonb
language sql volatile security invoker set search_path='' set statement_timeout='10s' as $$
 select taskfold_private.automation_cancel_key(_account,_session,_id)
$$;
revoke all on function public.taskfold_automation_cancel_key(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.taskfold_automation_cancel_key(uuid,uuid,uuid) to service_role;
