-- Local candidate: install inactive. Operator enables retention after acceptance.
-- No network, provider credential, email content or task mutation in this job.
create table taskfold_private.email_maintenance (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default false,
 after_account uuid,
 last_run_at timestamptz,
 last_counts jsonb not null default '{}'::jsonb
);
alter table taskfold_private.email_maintenance enable row level security;
revoke all on taskfold_private.email_maintenance from public,anon,authenticated,service_role;
insert into taskfold_private.email_maintenance default values;
create index email_routes_revoked_maintenance on taskfold_private.email_routes(user_id,updated_at,id) where state='revoked';

-- Three index-ordered branches avoid aggregating all retained account history.
-- Cursor wraps on the next empty range. Each branch and the union return <=20.
create function taskfold_private.email_maintenance_accounts(_after uuid,_cutoff timestamptz)
returns table(account uuid) language sql stable security invoker set search_path='' as $$
 select x.user_id from (
  (select distinct user_id from taskfold_private.email_deliveries
   where (_after is null or user_id>_after) and created_at<_cutoff and received_at<_cutoff order by user_id limit 20)
  union
  (select distinct user_id from taskfold_private.email_routes
   where (_after is null or user_id>_after) and state='revoked' and updated_at<_cutoff
    and not exists(select 1 from taskfold_private.email_deliveries d where d.route_id=email_routes.id)
   order by user_id limit 20)
  union
  (select distinct user_id from taskfold_private.email_route_cancellations
   where (_after is null or user_id>_after) and created_at<_cutoff order by user_id limit 20)
 ) x order by x.user_id limit 20
$$;
revoke all on function taskfold_private.email_maintenance_accounts(uuid,timestamptz) from public,anon,authenticated,service_role;

create function taskfold_private.run_email_maintenance() returns jsonb
language plpgsql volatile security invoker set search_path='' set lock_timeout='250ms' as $$
declare state taskfold_private.email_maintenance; cutoff timestamptz:=clock_timestamp()-interval '30 days';
 accounts uuid[]; account uuid; visited integer:=0; skipped integer:=0;
 deliveries integer:=0; routes integer:=0; cancellations integer:=0; nd integer; nr integer; nc integer; result jsonb;
begin
 -- Never overlap ticks or wait behind another maintenance transaction.
 if not pg_try_advisory_xact_lock(hashtextextended('taskfold.email.maintenance',11819)) then
  return jsonb_build_object('state','busy');
 end if;
 select * into state from taskfold_private.email_maintenance where singleton for update skip locked;
 if not found then return jsonb_build_object('state','busy');end if;
 if not state.enabled then return jsonb_build_object('state','disabled');end if;
 -- A later database restart may change the executor after enablement. Refuse
 -- cleanup then too, while leaving an aggregate health signal for the operator.
 if current_setting('cron.use_background_workers',true)='on' then
  result:=jsonb_build_object('state','unsupported_scheduler');
  update taskfold_private.email_maintenance set last_run_at=clock_timestamp(),last_counts=result where singleton;
  return result;
 end if;
 select array_agg(account_id order by account_id) into accounts
  from taskfold_private.email_maintenance_accounts(state.after_account,cutoff) as a(account_id);
 if accounts is null then
  select array_agg(account_id order by account_id) into accounts
   from taskfold_private.email_maintenance_accounts(null,cutoff) as a(account_id);
 end if;
 foreach account in array coalesce(accounts,'{}'::uuid[]) loop
  visited:=visited+1;
  -- Same transaction lock as intake, route management and account removal.
  -- Busy accounts are revisited after the cursor wraps, not allowed to starve others.
  if not pg_try_advisory_xact_lock(hashtextextended('automation:'||account::text,11819)) then
   skipped:=skipped+1;continue;
  end if;
  nd:=0;nr:=0;nc:=0;
  begin
   with old as (select route_id,delivery_key from taskfold_private.email_deliveries
    where user_id=account and created_at<cutoff and received_at<cutoff
    order by created_at,route_id,delivery_key limit 500 for update skip locked)
   delete from taskfold_private.email_deliveries d using old
    where d.route_id=old.route_id and d.delivery_key=old.delivery_key;
   get diagnostics nd=row_count;
   with old as (select id from taskfold_private.email_routes r
    where r.user_id=account and r.state='revoked' and updated_at<cutoff
     and not exists(select 1 from taskfold_private.email_deliveries d where d.route_id=r.id)
    order by updated_at,id limit 500 for update skip locked)
   delete from taskfold_private.email_routes r using old where r.id=old.id;
   get diagnostics nr=row_count;
   with old as (select id from taskfold_private.email_route_cancellations
    where user_id=account and created_at<cutoff order by created_at,id limit 500 for update skip locked)
   delete from taskfold_private.email_route_cancellations c using old where c.id=old.id;
   get diagnostics nc=row_count;
  exception when lock_not_available then
   -- Per-account subtransaction rolls back all three deletions together.
   -- Never persist SQLERRM, identifiers or mail metadata into monitoring.
   skipped:=skipped+1;
   -- PL/pgSQL variables survive rollback: discard speculative counts.
   nd:=0;nr:=0;nc:=0;
  end;
  deliveries:=deliveries+nd;routes:=routes+nr;cancellations:=cancellations+nc;
 end loop;
 result:=jsonb_build_object('state','finished','accounts',visited,'skipped',skipped,
  'deliveries',deliveries,'routes',routes,'cancellations',cancellations);
 update taskfold_private.email_maintenance set after_account=case when accounts is null then null else accounts[array_length(accounts,1)] end,
  last_run_at=clock_timestamp(),last_counts=result where singleton;
 return result;
end$$;
revoke all on function taskfold_private.run_email_maintenance() from public,anon,authenticated,service_role;

create function taskfold_private.configure_email_maintenance(_enabled boolean) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare job bigint;
begin
 if _enabled is null then raise exception 'Email maintenance configuration is invalid.';end if;
 -- pg_cron's background-worker executor arms statement_timeout before parsing
 -- the command, so its later SET cannot bound this job. Do not silently enable
 -- that unsupported mode or change the project's global scheduler settings.
 if _enabled and current_setting('cron.use_background_workers',true)='on' then
  raise exception 'Email maintenance requires pg_cron connection mode for its deadline.';
 end if;
 select jobid into job from cron.job where jobname='taskfold-email-maintenance';
 if job is null then raise exception 'Email maintenance job is unavailable.';end if;
 update taskfold_private.email_maintenance set enabled=_enabled where singleton;
 perform cron.alter_job(job,active:=_enabled);
end$$;
revoke all on function taskfold_private.configure_email_maintenance(boolean) from public,anon,authenticated,service_role;

-- Same transaction installs and disables. Cron command applies a real statement
-- deadline before SELECT starts in the supported libpq connection mode.
-- Background-worker mode is explicitly refused at configuration time.
do $$declare job bigint;begin
 job:=cron.schedule('taskfold-email-maintenance','*/5 * * * *',
  'set statement_timeout=''20s''; set lock_timeout=''250ms''; select taskfold_private.run_email_maintenance();');
 perform cron.alter_job(job,active:=false);
end$$;
