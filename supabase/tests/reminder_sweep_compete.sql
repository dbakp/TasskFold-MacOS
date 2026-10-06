-- Connection B must actually overlap A; the transactional marker prevents a false pass.
begin;
do $$ begin
 if not exists(select 1 from pg_catalog.pg_locks where locktype='advisory'
  and classid=0 and objid=643332100 and objsubid=1 and granted
  and database=(select oid from pg_catalog.pg_database where datname=current_database()))
 then raise exception 'Holder is not running; no overlap was proved.'; end if;
end $$;
set local role service_role;
do $$ begin
 if public.taskfold_claim_reminder_sweep() is not null
 then raise exception 'Competing worker obtained the locked sweep.'; end if;
end $$;
select true as competitor_skipped;
rollback;
