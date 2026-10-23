-- TEST BRANCH ONLY. No production migration. Apply before creating test users.
-- Owned injected waits exercise unchanged production RPCs through PostgREST.
do $$ begin
 if exists(select 1 from auth.users) then raise exception 'Requires an empty disposable branch';end if;
end $$;
create schema taskfold_acceptance;
revoke all on schema taskfold_acceptance from public,anon,authenticated,service_role;
create table taskfold_acceptance.deadline_controls(
 id uuid not null,
 user_id uuid not null references auth.users(id) on delete cascade,
 kind text not null check(kind in('keys','tasks')),
 seconds double precision not null check(seconds between 0 and 12),
 primary key(id,kind)
);
alter table taskfold_acceptance.deadline_controls enable row level security;
revoke all on taskfold_acceptance.deadline_controls from public,anon,authenticated,service_role;
create function taskfold_acceptance.delay_insert() returns trigger language plpgsql security definer set search_path='' as $$
declare duration double precision;
begin
 select c.seconds into duration from taskfold_acceptance.deadline_controls c
 where c.id=new.id and c.user_id=new.user_id and c.kind=case when tg_table_name='tasks' then 'tasks' else 'keys' end;
 if duration>0 then
  perform set_config('application_name','taskfold-deadline-'||new.id::text,true);
  perform pg_sleep(duration);
 end if;
 return new;
end $$;
revoke all on function taskfold_acceptance.delay_insert() from public,anon,authenticated,service_role;
create trigger taskfold_acceptance_delay before insert on taskfold_private.automation_keys for each row execute function taskfold_acceptance.delay_insert();
create trigger taskfold_acceptance_delay before insert on public.tasks for each row execute function taskfold_acceptance.delay_insert();
create function public.taskfold_acceptance_deadline_control(_id uuid,_account uuid,_kind text,_seconds double precision)
returns jsonb language plpgsql security definer set search_path='' set statement_timeout='2s' as $$
begin
 insert into taskfold_acceptance.deadline_controls values(_id,_account,_kind,_seconds)
 on conflict(id,kind) do update set seconds=excluded.seconds where deadline_controls.user_id=excluded.user_id;
 return jsonb_build_object('ready',true);
end $$;
create function public.taskfold_acceptance_deadline_hold(_id uuid,_account uuid)
returns jsonb language plpgsql security definer set search_path='' set statement_timeout='12s' set lock_timeout='500ms' as $$
begin
 if not exists(select 1 from auth.users where id=_account) then raise exception 'Fixture account missing';end if;
 perform set_config('application_name','taskfold-holder-'||_id::text,true);
 perform pg_advisory_xact_lock(hashtextextended('automation:'||_account::text,11819));
 perform pg_sleep(8);
 return jsonb_build_object('released',true);
end $$;
create function public.taskfold_acceptance_deadline_state(_id uuid,_request uuid default null)
returns jsonb language sql stable security definer set search_path='' set statement_timeout='2s' as $$
 select jsonb_build_object(
 'holder',exists(select from pg_stat_activity where application_name='taskfold-holder-'||_id::text and wait_event='PgSleep'),
 'blocked',(select count(*) from pg_stat_activity a where exists(select from pg_stat_activity h where h.application_name='taskfold-holder-'||_id::text and h.pid=any(pg_blocking_pids(a.pid)))),
 'inserting',exists(select from pg_stat_activity where application_name='taskfold-deadline-'||_id::text and state='active'),
 'keys',(select count(*) from taskfold_private.automation_keys where id=_id),
 'tasks',(select count(*) from public.tasks where id=_id),
 'journal',(select count(*) from taskfold_private.automation_requests where request_id=_request))
$$;
revoke all on function public.taskfold_acceptance_deadline_control(uuid,uuid,text,double precision),public.taskfold_acceptance_deadline_hold(uuid,uuid),public.taskfold_acceptance_deadline_state(uuid,uuid) from public,anon,authenticated;
grant execute on function public.taskfold_acceptance_deadline_control(uuid,uuid,text,double precision),public.taskfold_acceptance_deadline_hold(uuid,uuid),public.taskfold_acceptance_deadline_state(uuid,uuid) to service_role;
notify pgrst,'reload schema';
