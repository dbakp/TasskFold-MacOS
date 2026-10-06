-- Keep Auth session rows private: queue routines use a service-only boolean lookup.
create function taskfold_private.reminder_session_live(_session uuid,_owner uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.sessions where id=_session and user_id=_owner and (not_after is null or not_after>now()))
$$;
revoke all on function taskfold_private.reminder_session_live(uuid,uuid) from public,anon,authenticated;
grant execute on function taskfold_private.reminder_session_live(uuid,uuid) to service_role;

create or replace function taskfold_private.reminder_job_current(j taskfold_private.reminder_jobs)
returns boolean language sql stable security invoker set search_path = '' as $$
 select exists(select 1 from taskfold_private.reminder_devices d
  join public.tasks t on t.id=j.task_id and t.user_id=d.user_id
  cross join lateral taskfold_private.reminder_events(to_jsonb(t),d.binding->>'time_zone') e
  where d.id=j.device_id and d.user_id=j.user_id and d.revision=j.device_revision and d.expires_at>now()
   and taskfold_private.reminder_session_live(d.session_id,d.user_id) and d.binding->>'enabled'='true' and d.binding->>'permission' in ('authorized','provisional')
   and (t.project_id is null or public.has_project_access(d.user_id,t.project_id))
   and e.spec_id=j.spec_id and e.signature=j.signature and e.fire_at=j.fire_at)
$$;

create or replace function taskfold_private.reconcile_reminder_jobs(_device uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare d taskfold_private.reminder_devices; n int; cutoff timestamptz:=clock_timestamp();
begin
 perform pg_advisory_xact_lock(hashtextextended(_device::text,78136));
 select * into d from taskfold_private.reminder_devices where id=_device for update;
 if not found then return jsonb_build_object('queued',0); end if;
 update taskfold_private.reminder_jobs j set state='cancelled',outcome='obsolete',lease_token=null,lease_until=null,updated_at=cutoff
  where device_id=_device and state in ('pending','leased') and not taskfold_private.reminder_job_current(j);
 if d.expires_at<=cutoff or not taskfold_private.reminder_session_live(d.session_id,d.user_id)
   or coalesce(d.binding->>'enabled','false')<>'true' or d.binding->>'permission' not in ('authorized','provisional') then return jsonb_build_object('queued',0); end if;
 insert into taskfold_private.reminder_jobs(id,device_id,user_id,task_id,spec_id,signature,fire_at,device_revision,next_attempt)
 select encode(extensions.digest(d.user_id::text||'|'||d.id::text||'|'||t.id::text||'|'||e.spec_id::text||'|'||e.signature,'sha256'),'hex'),
  d.id,d.user_id,t.id,e.spec_id,e.signature,e.fire_at,d.revision,e.fire_at
 from public.tasks t cross join lateral taskfold_private.reminder_events(to_jsonb(t),d.binding->>'time_zone') e
 where t.user_id=d.user_id and not t.completed and (t.due_date is not null or t.reminder_specs<>'[]'::jsonb)
  and (t.project_id is null or public.has_project_access(d.user_id,t.project_id)) and e.fire_at between cutoff-interval '1 hour' and cutoff+interval '7 days'
 on conflict(id) do update set device_revision=excluded.device_revision,state='pending',outcome=null,lease_token=null,lease_until=null,next_attempt=excluded.fire_at,updated_at=cutoff
  where reminder_jobs.state='cancelled' and reminder_jobs.fire_at>cutoff;
 get diagnostics n=row_count;
 return jsonb_build_object('queued',n);
end $$;

create or replace function taskfold_private.maintain_reminder_queue(_limit int default 1000)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare retired int; removed int;
begin
 if _limit is null or _limit not between 1 and 1000 then raise exception 'Invalid maintenance batch size.'; end if;
 with expired as (select d.id from taskfold_private.reminder_devices d where d.binding is not null and
  (d.expires_at<=clock_timestamp() or not taskfold_private.reminder_session_live(d.session_id,d.user_id))
  order by d.expires_at,d.id for update of d skip locked limit _limit)
 update taskfold_private.reminder_devices d set user_id=null,session_id=null,binding=null,token_hash=null,expires_at=now(),updated_at=now() from expired e where d.id=e.id;
 get diagnostics retired=row_count;
 with terminal as (select id from taskfold_private.reminder_jobs where state in ('sent','failed','cancelled') and fire_at<clock_timestamp()-interval '8 days' order by fire_at,id for update skip locked limit _limit)
 delete from taskfold_private.reminder_jobs j using terminal t where j.id=t.id;
 get diagnostics removed=row_count;
 return jsonb_build_object('retired',retired,'removed',removed);
end $$;
