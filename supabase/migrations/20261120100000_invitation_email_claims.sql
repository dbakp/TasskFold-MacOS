begin;

-- Server-side bookkeeping for the send-invitation-email edge function. It lives
-- outside public.project_collaborators on purpose: that table's invitation guard
-- trigger rejects service-role updates, and clients must never see or write this.
-- No foreign keys: rows only hold ids, are pruned after a day, and must not take
-- part in account removal.
create table if not exists taskfold_private.invitation_email_claims(
 id bigint generated always as identity primary key,
 invitation_id uuid not null,
 sent_by uuid not null,
 claimed_at timestamptz not null default now()
);
create index if not exists invitation_email_claims_invitation_idx on taskfold_private.invitation_email_claims(invitation_id, claimed_at desc);
create index if not exists invitation_email_claims_sender_idx on taskfold_private.invitation_email_claims(sent_by, claimed_at desc);
alter table taskfold_private.invitation_email_claims enable row level security;
revoke all on taskfold_private.invitation_email_claims from public, anon, authenticated;

-- One claim per invitation per 10 minutes and at most 20 claims per sender per
-- hour, decided atomically here rather than in function memory.
create or replace function public.taskfold_claim_invitation_email(_invitation uuid, _user uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare recent timestamptz; used integer; claim bigint;
begin
 if _invitation is null or _user is null then raise exception 'Invitation and sender are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('taskfold_invitation_email:' || _user::text, 0));
 delete from taskfold_private.invitation_email_claims where claimed_at < now() - interval '1 day';
 select max(claimed_at) into recent from taskfold_private.invitation_email_claims where invitation_id = _invitation;
 if recent is not null and recent > now() - interval '10 minutes' then
  return jsonb_build_object('status', 'recent');
 end if;
 select count(*) into used from taskfold_private.invitation_email_claims where sent_by = _user and claimed_at > now() - interval '1 hour';
 if used >= 20 then return jsonb_build_object('status', 'rate_limited'); end if;
 insert into taskfold_private.invitation_email_claims(invitation_id, sent_by) values (_invitation, _user) returning id into claim;
 return jsonb_build_object('status', 'claimed', 'claim', claim);
end $$;

-- A provider failure gives the claim back so a retry is not locked out.
create or replace function public.taskfold_release_invitation_email(_claim bigint)
returns void language sql volatile security definer set search_path = '' as $$
 delete from taskfold_private.invitation_email_claims where id = _claim;
$$;

revoke all on function public.taskfold_claim_invitation_email(uuid, uuid), public.taskfold_release_invitation_email(bigint) from public, anon, authenticated;
grant execute on function public.taskfold_claim_invitation_email(uuid, uuid), public.taskfold_release_invitation_email(bigint) to service_role;

commit;
