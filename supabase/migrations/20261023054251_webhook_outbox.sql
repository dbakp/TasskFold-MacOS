-- Inactive candidate. Durable capture/leases only; no scheduler is installed.
-- Lock order: subscription key/share -> budget -> existing event. Task capture
-- already owns its source task and inserts fresh events only. No network I/O
-- occurs inside a database transaction, and claims skip busy subscription rows.
create table taskfold_private.webhook_budgets (
 subscription_id uuid primary key,
 user_id uuid not null,
 capture_day date not null default (clock_timestamp() at time zone 'UTC')::date,
 day_events integer not null default 0 check(day_events between 0 and 500),
 day_bytes integer not null default 0 check(day_bytes between 0 and 33554432),
 pending integer not null default 0 check(pending between 0 and 256),
 retained_bytes integer not null default 0 check(retained_bytes between 0 and 33554432),
 send_window timestamptz not null default clock_timestamp(),
 window_sends integer not null default 0 check(window_sends between 0 and 60),
 send_day date not null default (clock_timestamp() at time zone 'UTC')::date,
 day_sends integer not null default 0 check(day_sends between 0 and 1000),
 lease_id uuid,
 lease_until timestamptz,
 blocked_reason text check(blocked_reason in('configuration','refused','gone')),
 blocked_until timestamptz,
 missed integer not null default 0 check(missed>=0),
 capture_issue text check(capture_issue in('event_quota','queue_capacity','payload_too_large')),
 missed_since timestamptz,
 missed_until timestamptz,
 delivered integer not null default 0 check(delivered>=0),
 failed integer not null default 0 check(failed>=0),
 last_success timestamptz,
 last_failure timestamptz,
 last_error text,
 foreign key(user_id,subscription_id) references taskfold_private.webhook_subscriptions(user_id,id) on delete cascade,
 check((lease_id is null)=(lease_until is null))
);
create table taskfold_private.webhook_outbox (
 id uuid primary key,
 user_id uuid not null,
 subscription_id uuid not null,
 task_id uuid not null,
 task_generation uuid not null,
 access_owner uuid not null,
 access_project uuid,
 event_type text not null check(event_type in('task.created','task.updated','task.completed','task.reopened','task.deleted','task.removed')),
 minimal boolean not null,
 payload text,
 payload_bytes integer not null check(payload_bytes between 1 and 16777216),
 payload_sha256 text not null check(payload_sha256~'^[a-f0-9]{64}$'),
 part_count integer not null check(part_count between 1 and 94),
 next_part integer not null default 0 check(next_part>=0),
 part_attempts integer not null default 0 check(part_attempts between 0 and 12),
 total_attempts integer not null default 0 check(total_attempts>=0),
 manual_retries integer not null default 0 check(manual_retries between 0 and 3),
 status text not null default 'pending' check(status in('pending','leased','failed','delivered','cancelled','expired')),
 created_at timestamptz not null,
 expires_at timestamptz not null,
 next_attempt_at timestamptz not null,
 finished_at timestamptz,
 last_error text,
 http_status integer check(http_status between 100 and 599),
 lease_id uuid,
 lease_revision uuid,
 lease_until timestamptz,
 authorized_at timestamptz,
 foreign key(user_id,subscription_id) references taskfold_private.webhook_subscriptions(user_id,id) on delete cascade,
 check(next_part<=part_count),
 check((status='leased')=(lease_id is not null)),
 check((lease_id is null)=(lease_revision is null) and (lease_id is null)=(lease_until is null)),
 check(authorized_at is null or status='leased'),
 check(status not in('pending','leased') or payload is not null),
 check(status not in('delivered','cancelled','expired') or payload is null)
);
create index webhook_outbox_subscription_order on taskfold_private.webhook_outbox(subscription_id,created_at,id);
create index webhook_outbox_due on taskfold_private.webhook_outbox(next_attempt_at,subscription_id,id) where status in('pending','leased');
create index webhook_outbox_expiry on taskfold_private.webhook_outbox(expires_at,subscription_id) where payload is not null;
create index webhook_outbox_history_expiry on taskfold_private.webhook_outbox(finished_at,id) where payload is null;
create table taskfold_private.webhook_retry_receipts (
 user_id uuid not null,
 request_id uuid not null,
 event_id uuid not null references taskfold_private.webhook_outbox(id) on delete cascade,
 applied_at timestamptz not null default clock_timestamp(),
 primary key(user_id,request_id)
);
create index webhook_retry_receipts_event on taskfold_private.webhook_retry_receipts(event_id);
create function taskfold_private.webhook_retry_guard() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if tg_op='DELETE' then
  if exists(select 1 from taskfold_private.webhook_outbox where id=old.event_id) then raise exception using errcode='PT409',message='Delivery retry history is retained with its event';end if;
  return old;
 end if;
 if to_jsonb(new) is distinct from to_jsonb(old) then raise exception using errcode='PT409',message='Delivery retry identity cannot change';end if;
 return new;end$$;
revoke all on function taskfold_private.webhook_retry_guard() from public,anon,authenticated,service_role;
create trigger webhook_retry_guard before update or delete on taskfold_private.webhook_retry_receipts for each row execute function taskfold_private.webhook_retry_guard();
alter table taskfold_private.webhook_budgets enable row level security;
alter table taskfold_private.webhook_outbox enable row level security;
alter table taskfold_private.webhook_retry_receipts enable row level security;
revoke all on taskfold_private.webhook_budgets,taskfold_private.webhook_outbox,taskfold_private.webhook_retry_receipts from public,anon,authenticated,service_role;
create index webhook_subscriptions_capture on taskfold_private.webhook_subscriptions(user_id,id) where verified_at is not null and state in('active','paused');
create index taskfold_webhook_accepted_members on public.project_collaborators(project_id,user_id) where status='accepted';

create function taskfold_private.webhook_budget_created() returns trigger
language plpgsql security definer set search_path='' as $$begin
 insert into taskfold_private.webhook_budgets(subscription_id,user_id) values(new.id,new.user_id);
 return new;end$$;
revoke all on function taskfold_private.webhook_budget_created() from public,anon,authenticated,service_role;
create trigger webhook_budget_created after insert on taskfold_private.webhook_subscriptions for each row execute function taskfold_private.webhook_budget_created();
insert into taskfold_private.webhook_budgets(subscription_id,user_id) select id,user_id from taskfold_private.webhook_subscriptions;

create function taskfold_private.webhook_outbox_guard() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if tg_op='DELETE' then
  if exists(select 1 from auth.users where id=old.user_id) and (old.payload is not null or old.finished_at is null or old.finished_at>clock_timestamp()-interval '7 days') then
   raise exception using errcode='PT409',message='Webhook event history is still retained';end if;
  return old;
 end if;
 if row(new.id,new.user_id,new.subscription_id,new.task_id,new.task_generation,new.access_owner,new.access_project,new.event_type,new.minimal,new.payload_bytes,new.payload_sha256,new.part_count,new.created_at,new.expires_at)
  is distinct from row(old.id,old.user_id,old.subscription_id,old.task_id,old.task_generation,old.access_owner,old.access_project,old.event_type,old.minimal,old.payload_bytes,old.payload_sha256,old.part_count,old.created_at,old.expires_at)
  or (new.payload is distinct from old.payload and not(new.payload is null and new.status in('delivered','cancelled','expired')))
  or (old.status in('delivered','cancelled','expired') and new.status<>old.status) then
  raise exception using errcode='PT409',message='Webhook event identity cannot change';end if;
 return new;end$$;
revoke all on function taskfold_private.webhook_outbox_guard() from public,anon,authenticated,service_role;
create trigger webhook_outbox_guard before update or delete on taskfold_private.webhook_outbox for each row execute function taskfold_private.webhook_outbox_guard();

create function taskfold_private.webhook_capture_available(t public.tasks) returns boolean
language sql stable security invoker set search_path='' as $$select exists(
 select 1 from taskfold_private.webhook_subscriptions h where h.verified_at is not null and h.state in('active','paused') and h.expires_at>clock_timestamp()
 and (case when t.project_id is null then h.user_id=t.user_id else h.user_id in(select user_id from public.projects where id=t.project_id union select user_id from public.project_collaborators where project_id=t.project_id and status='accepted') end)
 and (h.scope='all' or (h.scope='inbox' and t.project_id is null) or (h.scope='project' and h.project_id=t.project_id)))$$;
revoke all on function taskfold_private.webhook_capture_available(public.tasks) from public,anon,authenticated,service_role;

-- Quota counters are short database locks, never held while waiting on a receiver.
-- Over-limit captures leave an explicit durable warning; task editing still saves.
create function taskfold_private.webhook_enqueue(t public.tasks,kind text,small boolean,new_location public.tasks default null) returns void
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
declare s taskfold_private.webhook_subscriptions;b taskfold_private.webhook_budgets;stamp timestamptz;today date;event_id uuid;body text;bytes integer;issue text;projection jsonb;
begin
 for s in select h.* from taskfold_private.webhook_subscriptions h
  where h.verified_at is not null and h.state in('active','paused') and h.expires_at>clock_timestamp()
  and (case when t.project_id is null then h.user_id=t.user_id else h.user_id in
   (select user_id from public.projects where id=t.project_id union select user_id from public.project_collaborators where project_id=t.project_id and status='accepted') end)
  and (h.scope='all' or (h.scope='inbox' and t.project_id is null) or (h.scope='project' and h.project_id=t.project_id))
  and (case when kind='task.removed' then 'task.updated' else kind end)=any(h.events)
  and not exists(select 1 from taskfold_private.webhook_removal_blocks r where r.user_id=h.user_id)
  and exists(select 1 from auth.users u where u.id=h.user_id and (u.banned_until is null or u.banned_until<=clock_timestamp()))
  order by h.id for key share of h skip locked loop
  if kind='task.removed' and new_location.id is not null and
   (s.scope='all' or (s.scope='inbox' and new_location.project_id is null) or (s.scope='project' and s.project_id=new_location.project_id))
   and ((new_location.project_id is null and new_location.user_id=s.user_id) or public.has_project_access(s.user_id,new_location.project_id)) then continue;end if;
  select * into b from taskfold_private.webhook_budgets where subscription_id=s.id for update;
  if not found then continue;end if;
  stamp=clock_timestamp();today=(stamp at time zone 'UTC')::date;
  if b.capture_day<>today then b.capture_day=today;b.day_events=0;b.day_bytes=0;end if;
  event_id=gen_random_uuid();
  projection=case when small then jsonb_build_object('id',t.id,'task_generation',coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000'::uuid),'project_id',t.project_id)
   else taskfold_private.automation_task_projection(t)||jsonb_build_object('task_generation',coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000'::uuid)) end;
  body=jsonb_build_object('version',1,'event_id',event_id,'type',kind,'occurred_at',stamp,'task',projection)::text;bytes=octet_length(body);
  issue=case when bytes>16777216 then 'payload_too_large' when b.day_events>=500 or b.day_bytes::bigint+bytes>33554432 then 'event_quota' when b.pending>=256 or b.retained_bytes::bigint+bytes>33554432 then 'queue_capacity' else null end;
  if issue is not null then
   update taskfold_private.webhook_budgets set capture_day=today,day_events=b.day_events,day_bytes=b.day_bytes,
    missed=least(2147483646,missed)+1,capture_issue=issue,missed_since=coalesce(missed_since,stamp),missed_until=stamp where subscription_id=s.id;
   continue;
  end if;
  insert into taskfold_private.webhook_outbox(id,user_id,subscription_id,task_id,task_generation,access_owner,access_project,event_type,minimal,payload,payload_bytes,payload_sha256,part_count,created_at,expires_at,next_attempt_at)
   values(event_id,s.user_id,s.id,t.id,coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000'::uuid),t.user_id,t.project_id,kind,small,body,bytes,
    encode(extensions.digest(convert_to(body,'UTF8'),'sha256'),'hex'),case when bytes<=250000 then 1 else (bytes+179999)/180000 end,stamp,stamp+interval '24 hours',stamp);
  update taskfold_private.webhook_budgets set capture_day=today,day_events=b.day_events+1,day_bytes=b.day_bytes+bytes,pending=pending+1,retained_bytes=retained_bytes+bytes where subscription_id=s.id;
 end loop;
end$$;
revoke all on function taskfold_private.webhook_enqueue(public.tasks,text,boolean,public.tasks) from public,anon,authenticated,service_role;
create function taskfold_private.webhook_capture_task() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if tg_op='INSERT' then perform taskfold_private.webhook_enqueue(new,'task.created',false);return new;end if;
 if tg_op='DELETE' then perform taskfold_private.webhook_enqueue(old,'task.deleted',true);return old;end if;
 if not taskfold_private.webhook_capture_available(old) and not taskfold_private.webhook_capture_available(new) then return new;end if;
 if (taskfold_private.automation_task_projection(new)-array['revision','notification_sent_at']) is not distinct from
    (taskfold_private.automation_task_projection(old)-array['revision','notification_sent_at']) then return new;end if;
 if row(new.project_id,new.user_id) is distinct from row(old.project_id,old.user_id) then perform taskfold_private.webhook_enqueue(old,'task.removed',true,new);end if;
 perform taskfold_private.webhook_enqueue(new,'task.updated',false);
 if new.completed is distinct from old.completed then perform taskfold_private.webhook_enqueue(new,case when new.completed then 'task.completed' else 'task.reopened' end,false);end if;
 return new;end$$;
revoke all on function taskfold_private.webhook_capture_task() from public,anon,authenticated,service_role;
create trigger zz_taskfold_webhook_capture after insert or update or delete on public.tasks for each row execute function taskfold_private.webhook_capture_task();

-- A deliberate native Resume (including an active connection blocked by a
-- receiver failure) clears the delivery block. Replayed commands return their
-- receipt without UPDATE, so they cannot clear a newer failure accidentally.
create function taskfold_private.webhook_delivery_resume() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if new.state='active' then update taskfold_private.webhook_budgets set blocked_reason=null,blocked_until=null where subscription_id=new.id;end if;
 return new;end$$;
revoke all on function taskfold_private.webhook_delivery_resume() from public,anon,authenticated,service_role;
create trigger webhook_delivery_resume after update on taskfold_private.webhook_subscriptions for each row execute function taskfold_private.webhook_delivery_resume();

-- Caller already owns subscription -> budget -> event locks. Failed messages
-- retain their immutable body for up to 24h so an explicit retry can reuse IDs.
create function taskfold_private.webhook_terminal(e taskfold_private.webhook_outbox,kind text,reason text) returns void
language plpgsql volatile security invoker set search_path='' as $$begin
 update taskfold_private.webhook_budgets set pending=pending-case when e.status in('pending','leased') then 1 else 0 end,
  retained_bytes=retained_bytes-case when kind<>'failed' and e.payload is not null then e.payload_bytes else 0 end,
  failed=case when kind in('failed','expired') and e.status<>'failed' then least(2147483646,failed)+1 else failed end,
  delivered=case when kind='delivered' then least(2147483646,delivered)+1 else delivered end,
  last_success=case when kind='delivered' then clock_timestamp() else last_success end,
  last_failure=case when kind in('failed','expired') then clock_timestamp() else last_failure end,last_error=reason,
  lease_id=case when lease_id=e.lease_id then null else lease_id end,lease_until=case when lease_id=e.lease_id then null else lease_until end
  where subscription_id=e.subscription_id;
 update taskfold_private.webhook_outbox set status=kind,payload=case when kind='failed' then payload else null end,
  finished_at=clock_timestamp(),last_error=reason,lease_id=null,lease_revision=null,lease_until=null,authorized_at=null,
  next_part=case when kind='delivered' then part_count else next_part end where id=e.id;
end$$;
revoke all on function taskfold_private.webhook_terminal(taskfold_private.webhook_outbox,text,text) from public,anon,authenticated,service_role;

create function taskfold_private.webhook_sweep() returns integer
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare s taskfold_private.webhook_subscriptions;b taskfold_private.webhook_budgets;e taskfold_private.webhook_outbox;n int:=0;
begin
 for s in select h.* from taskfold_private.webhook_subscriptions h where exists(select 1 from taskfold_private.webhook_outbox x where x.subscription_id=h.id and
  ((x.payload is not null and (x.expires_at<=clock_timestamp() or h.state='revoked' or h.expires_at<=clock_timestamp() or exists(select 1 from taskfold_private.webhook_removal_blocks r where r.user_id=h.user_id)))
   or (x.payload is null and x.finished_at<clock_timestamp()-interval '7 days')))
  order by h.id limit 8 for key share of h skip locked loop
  select * into b from taskfold_private.webhook_budgets where subscription_id=s.id for update skip locked;if not found then continue;end if;
  for e in select * from taskfold_private.webhook_outbox x where subscription_id=s.id and payload is not null and
   (expires_at<=clock_timestamp() or s.state='revoked' or s.expires_at<=clock_timestamp() or exists(select 1 from taskfold_private.webhook_removal_blocks r where r.user_id=s.user_id)) order by x.created_at,x.id limit 64 for update skip locked loop
    perform taskfold_private.webhook_terminal(e,case when e.expires_at<=clock_timestamp() then 'expired' else 'cancelled' end,case when e.expires_at<=clock_timestamp() then 'expired' else 'connection_unavailable' end);n=n+1;
  end loop;
  delete from taskfold_private.webhook_outbox where id in(select id from taskfold_private.webhook_outbox where subscription_id=s.id and payload is null and finished_at<clock_timestamp()-interval '7 days' order by finished_at,id limit 64 for update skip locked);
 end loop;
 return n;
end$$;
revoke all on function taskfold_private.webhook_sweep() from public,anon,authenticated,service_role;

create function taskfold_private.webhook_claim() returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare candidate record;s taskfold_private.webhook_subscriptions;b taskfold_private.webhook_budgets;e taskfold_private.webhook_outbox;stamp timestamptz;lease uuid;maintained int;
begin
 maintained=taskfold_private.webhook_sweep();
 for candidate in select x.id,x.subscription_id from taskfold_private.webhook_outbox x
  join taskfold_private.webhook_subscriptions h on h.id=x.subscription_id join taskfold_private.webhook_budgets q on q.subscription_id=h.id
  where x.status in('pending','leased') and x.next_attempt_at<=clock_timestamp() and x.expires_at>clock_timestamp()
  and h.state='active' and h.expires_at>clock_timestamp() and (q.blocked_reason is null or (q.blocked_reason='configuration' and q.blocked_until<=clock_timestamp()))
  and (q.lease_until is null or q.lease_until<=clock_timestamp())
  and not exists(select 1 from taskfold_private.webhook_outbox older where older.subscription_id=x.subscription_id and older.status in('pending','leased') and (older.created_at,older.id)<(x.created_at,x.id))
  order by x.next_attempt_at,x.created_at,x.id limit 32 loop
  select * into s from taskfold_private.webhook_subscriptions where id=candidate.subscription_id for key share skip locked;if not found then continue;end if;
  select * into b from taskfold_private.webhook_budgets where subscription_id=s.id for update skip locked;if not found then continue;end if;
  select * into e from taskfold_private.webhook_outbox where id=candidate.id for update skip locked;if not found then continue;end if;
  stamp=clock_timestamp();
  if s.state<>'active' or s.expires_at<=stamp or e.expires_at<=stamp or e.status not in('pending','leased') or e.next_attempt_at>stamp or b.lease_until>stamp then continue;end if;
  if b.blocked_reason is not null and not(b.blocked_reason='configuration' and b.blocked_until<=stamp) then continue;end if;
  lease=gen_random_uuid();
  update taskfold_private.webhook_budgets set lease_id=lease,lease_until=stamp+interval '45 seconds',blocked_reason=null,blocked_until=null where subscription_id=s.id;
  update taskfold_private.webhook_outbox set status='leased',lease_id=lease,lease_revision=s.revision,lease_until=stamp+interval '45 seconds',authorized_at=null where id=e.id;
  return jsonb_build_object('event_id',e.id,'lease_id',lease,'lease_until',stamp+interval '45 seconds','maintenance',maintained);
 end loop;
 return jsonb_build_object('event_id',null,'maintenance',maintained);
end$$;
revoke all on function taskfold_private.webhook_claim() from public,anon,authenticated,service_role;

-- Both packet preparation and the transport's after-TLS/before-write callback
-- reauthorize. No task/secret bytes are transmitted before the latter completes.
create function taskfold_private.webhook_prepare(_id uuid,_lease uuid,_authorize boolean) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
declare e taskfold_private.webhook_outbox;s taskfold_private.webhook_subscriptions;b taskfold_private.webhook_budgets;t public.tasks;stamp timestamptz;reason text;wire text;part uuid;hex text;defer_until timestamptz;
begin
 select * into e from taskfold_private.webhook_outbox where id=_id;if not found then return jsonb_build_object('ready',false,'reason','stale');end if;
 -- A failed account lock is recorded under the same short locking order below.
 begin perform taskfold_private.automation_account_lock(e.user_id);exception when sqlstate '28000' then reason='account_unavailable';end;
 if exists(select 1 from taskfold_private.webhook_removal_blocks where user_id=e.user_id) then reason='account_unavailable';end if;
 if not e.minimal and reason is null then
  select * into t from public.tasks where id=e.task_id for share;
  if not found or coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000'::uuid)<>e.task_generation or row(t.user_id,t.project_id) is distinct from row(e.access_owner,e.access_project) then reason='resource_unavailable';end if;
 end if;
 if reason is null then
  begin perform taskfold_private.automation_lock_task_access(e.user_id,e.access_owner,e.access_project);exception when sqlstate 'PT404' then reason='resource_unavailable';end;
 end if;
 select * into s from taskfold_private.webhook_subscriptions where id=e.subscription_id for share;
 if not found then return jsonb_build_object('ready',false,'reason','stale');end if;
 select * into b from taskfold_private.webhook_budgets where subscription_id=s.id for update;
 select * into e from taskfold_private.webhook_outbox where id=_id for update;
 stamp=clock_timestamp();
 if not found or e.status<>'leased' or e.lease_id is distinct from _lease or b.lease_id is distinct from _lease or e.lease_until<=stamp then return jsonb_build_object('ready',false,'reason','stale');end if;
 if reason is not null or s.state='revoked' or s.expires_at<=stamp or e.expires_at<=stamp then
  perform taskfold_private.webhook_terminal(e,case when e.expires_at<=stamp then 'expired' else 'cancelled' end,coalesce(reason,'connection_unavailable'));
  return jsonb_build_object('ready',false,'reason',coalesce(reason,'connection_unavailable'));
 end if;
 if s.state<>'active' or s.revision<>e.lease_revision or b.blocked_reason is not null then
  update taskfold_private.webhook_outbox set status='pending',lease_id=null,lease_revision=null,lease_until=null,authorized_at=null,next_attempt_at=stamp where id=e.id;
  update taskfold_private.webhook_budgets set lease_id=null,lease_until=null where subscription_id=s.id;
  return jsonb_build_object('ready',false,'reason','connection_changed');
 end if;
 if b.send_day<>(stamp at time zone 'UTC')::date then b.send_day=(stamp at time zone 'UTC')::date;b.day_sends=0;end if;
 if b.send_window<=stamp-interval '1 minute' then b.send_window=stamp;b.window_sends=0;end if;
 if e.authorized_at is null and (b.day_sends>=1000 or b.window_sends>=60) then
  defer_until=case when b.day_sends>=1000 then (date_trunc('day',stamp at time zone 'UTC') at time zone 'UTC')+interval '24 hours' else b.send_window+interval '1 minute' end;
  update taskfold_private.webhook_outbox set status='pending',lease_id=null,lease_revision=null,lease_until=null,authorized_at=null,next_attempt_at=defer_until,last_error='quota' where id=e.id;
  update taskfold_private.webhook_budgets set lease_id=null,lease_until=null,last_error='quota' where subscription_id=s.id;
  return jsonb_build_object('ready',false,'reason','quota');
 end if;
 if _authorize then
  if e.authorized_at is null then
   if e.part_attempts>=12 then perform taskfold_private.webhook_terminal(e,'failed','attempts_exhausted');return jsonb_build_object('ready',false,'reason','attempts_exhausted');end if;
   update taskfold_private.webhook_budgets set send_day=b.send_day,day_sends=b.day_sends+1,send_window=b.send_window,window_sends=b.window_sends+1 where subscription_id=s.id;
   update taskfold_private.webhook_outbox set authorized_at=stamp,part_attempts=part_attempts+1,total_attempts=total_attempts+1 where id=e.id;
  end if;
  return jsonb_build_object('ready',true,'lease_until',e.lease_until);
 end if;
 if e.part_count=1 then wire=e.payload;part=e.id;
 else
  hex=left(encode(extensions.digest(convert_to(e.id::text||':'||e.next_part::text,'UTF8'),'sha256'),'hex'),32);
  part=(substr(hex,1,8)||'-'||substr(hex,9,4)||'-'||substr(hex,13,4)||'-'||substr(hex,17,4)||'-'||substr(hex,21,12))::uuid;
  wire=jsonb_build_object('version',1,'type','taskfold.event.part','event_id',e.id,'part_id',part,'part_index',e.next_part,'part_count',e.part_count,'encoding','base64','sha256',e.payload_sha256,
   'data',replace(encode(substring(convert_to(e.payload,'UTF8') from e.next_part*180000+1 for 180000),'base64'),E'\n',''))::text;
 end if;
 return jsonb_build_object('ready',true,'event_id',e.id,'part_id',part,'subscription_id',s.id,'account',s.user_id,'endpoint',s.endpoint,'secret_envelope',s.secret_envelope,'body',wire,'lease_until',e.lease_until);
end$$;
revoke all on function taskfold_private.webhook_prepare(uuid,uuid,boolean) from public,anon,authenticated,service_role;

create function taskfold_private.webhook_ack(_id uuid,_lease uuid,_outcome text,_status integer,_retry integer) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare e taskfold_private.webhook_outbox;s taskfold_private.webhook_subscriptions;b taskfold_private.webhook_budgets;stamp timestamptz;delay integer;
begin
 select * into e from taskfold_private.webhook_outbox where id=_id;if not found then return jsonb_build_object('applied',false);end if;
 select * into s from taskfold_private.webhook_subscriptions where id=e.subscription_id for key share;if not found then return jsonb_build_object('applied',false);end if;
 select * into b from taskfold_private.webhook_budgets where subscription_id=s.id for update;
 select * into e from taskfold_private.webhook_outbox where id=_id for update;
 stamp=clock_timestamp();
 if not found or e.status<>'leased' or e.lease_id is distinct from _lease or b.lease_id is distinct from _lease or e.lease_until<=stamp then return jsonb_build_object('applied',false);end if;
 if _outcome='delivered' and e.authorized_at is not null then
  if e.next_part+1=e.part_count then perform taskfold_private.webhook_terminal(e,'delivered',null);
  else
   update taskfold_private.webhook_outbox set status='pending',next_part=next_part+1,part_attempts=0,lease_id=null,lease_revision=null,lease_until=null,authorized_at=null,next_attempt_at=stamp,last_error=null,http_status=_status where id=e.id;
   update taskfold_private.webhook_budgets set lease_id=null,lease_until=null where subscription_id=s.id;
  end if;
 elsif _outcome='configuration' then
  update taskfold_private.webhook_budgets set blocked_reason='configuration',blocked_until=stamp+interval '5 minutes',last_error='configuration',last_failure=stamp,lease_id=null,lease_until=null where subscription_id=s.id;
  update taskfold_private.webhook_outbox set status='pending',lease_id=null,lease_revision=null,lease_until=null,authorized_at=null,next_attempt_at=stamp+interval '5 minutes',last_error='configuration' where id=e.id;
 elsif _outcome in('refused','gone') then
  perform taskfold_private.webhook_terminal(e,'failed',_outcome);
  update taskfold_private.webhook_budgets set blocked_reason=_outcome,blocked_until=null where subscription_id=s.id;
 elsif _outcome='retry' or (_outcome='delivered' and e.authorized_at is null) then
  if e.part_attempts>=12 or e.expires_at<=stamp then perform taskfold_private.webhook_terminal(e,case when e.expires_at<=stamp then 'expired' else 'failed' end,case when e.expires_at<=stamp then 'expired' else 'attempts_exhausted' end);
  else
   delay=greatest(least(3600,(15*power(2,least(e.part_attempts,8)))::integer),coalesce(_retry,0));
   update taskfold_private.webhook_outbox set status='pending',lease_id=null,lease_revision=null,lease_until=null,authorized_at=null,next_attempt_at=least(expires_at,stamp+delay*interval '1 second'),last_error='temporary',http_status=_status where id=e.id;
   update taskfold_private.webhook_budgets set lease_id=null,lease_until=null,last_error='temporary',last_failure=stamp where subscription_id=s.id;
  end if;
 else raise exception using errcode='22023',message='Invalid delivery outcome';end if;
 if _status is not null then update taskfold_private.webhook_outbox set http_status=_status where id=e.id;end if;
 return jsonb_build_object('applied',true);
end$$;
revoke all on function taskfold_private.webhook_ack(uuid,uuid,text,integer,integer) from public,anon,authenticated,service_role;

create function taskfold_private.webhook_dispatch(_action text,_body jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
begin
 if _body is null or jsonb_typeof(_body)<>'object' or octet_length(_body::text)>4096 then raise exception using errcode='22023',message='Invalid worker request';end if;
 if _action in('claim','sweep') then
  if _body<>'{}'::jsonb then raise exception using errcode='22023',message='Invalid worker request';end if;
  if _action='sweep' then return jsonb_build_object('maintenance',taskfold_private.webhook_sweep());end if;
  return taskfold_private.webhook_claim();
 end if;
 if _action is null or _action not in('prepare','authorize','ack') or jsonb_typeof(_body->'event_id') is distinct from 'string' or jsonb_typeof(_body->'lease_id') is distinct from 'string'
  or (_body->>'event_id')!~'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' or (_body->>'lease_id')!~'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' then raise exception using errcode='22023',message='Invalid worker identity';end if;
 if _action in('prepare','authorize') then
  if (select count(*) from jsonb_object_keys(_body))<>2 then raise exception using errcode='22023',message='Invalid worker request';end if;
  return taskfold_private.webhook_prepare((_body->>'event_id')::uuid,(_body->>'lease_id')::uuid,_action='authorize');
 end if;
 if exists(select 1 from jsonb_object_keys(_body) k where k not in('event_id','lease_id','outcome','status','retry_after')) or jsonb_typeof(_body->'outcome') is distinct from 'string' or (_body->>'outcome') not in('delivered','retry','refused','gone','configuration')
  or (_body ? 'status' and (jsonb_typeof(_body->'status') is distinct from 'number' or (_body->>'status')::numeric not between 100 and 599 or (_body->>'status')::numeric<>trunc((_body->>'status')::numeric)))
  or (_body ? 'retry_after' and (jsonb_typeof(_body->'retry_after') is distinct from 'number' or (_body->>'retry_after')::numeric not between 1 and 86400 or (_body->>'retry_after')::numeric<>trunc((_body->>'retry_after')::numeric))) then raise exception using errcode='22023',message='Invalid worker outcome';end if;
 return taskfold_private.webhook_ack((_body->>'event_id')::uuid,(_body->>'lease_id')::uuid,_body->>'outcome',(_body->>'status')::integer,(_body->>'retry_after')::integer);
end$$;
revoke all on function taskfold_private.webhook_dispatch(text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.webhook_dispatch(text,jsonb) to service_role;
create function public.taskfold_webhook_dispatch(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' set statement_timeout='10s' as $$select taskfold_private.webhook_dispatch(_action,_body)$$;
revoke all on function public.taskfold_webhook_dispatch(text,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_webhook_dispatch(text,jsonb) to service_role;

create function taskfold_private.webhook_delivery_summary(_id uuid) returns jsonb
language sql volatile security invoker set search_path='' as $$select jsonb_build_object('version',1,'pending',b.pending,'retained_bytes',b.retained_bytes,
 'missed',b.missed,'capture_issue',b.capture_issue,'missed_since',b.missed_since,'missed_until',b.missed_until,
 'blocked_reason',b.blocked_reason,'last_error',b.last_error,'last_success',b.last_success,'last_failure',b.last_failure,'delivered',b.delivered,'failed',b.failed)
 from taskfold_private.webhook_budgets b where subscription_id=_id$$;
revoke all on function taskfold_private.webhook_delivery_summary(uuid) from public,anon,authenticated,service_role;
create or replace function taskfold_private.webhook_receipt(s taskfold_private.webhook_subscriptions) returns jsonb
language sql volatile security invoker set search_path='' as $$
 select jsonb_build_object('id',s.id,'revision',s.revision,'name',s.name,'origin',substring(s.endpoint from '^https://[^/]+'),
 'scope',s.scope,'project_id',s.project_id,'events',s.events,'created_at',s.created_at,'expires_at',s.expires_at,
 'state',case when s.state<>'revoked' and s.expires_at<=clock_timestamp() then 'expired' else s.state end,
 'verified_at',s.verified_at,'revoked_at',s.revoked_at,'delivery',taskfold_private.webhook_delivery_summary(s.id))
$$;

create function taskfold_private.webhook_event_receipt(e taskfold_private.webhook_outbox) returns jsonb
language sql stable security invoker set search_path='' as $$select jsonb_build_object('id',e.id,'task_id',e.task_id,'task_generation',e.task_generation,'type',e.event_type,
 'status',e.status,'created_at',e.created_at,'expires_at',e.expires_at,'finished_at',e.finished_at,'next_attempt_at',e.next_attempt_at,
 'parts',e.part_count,'parts_delivered',e.next_part,'attempts',e.total_attempts,'manual_retries',e.manual_retries,'error',e.last_error,'http_status',e.http_status)
$$;
revoke all on function taskfold_private.webhook_event_receipt(taskfold_private.webhook_outbox) from public,anon,authenticated,service_role;

create function taskfold_private.webhook_queue_native(_account uuid,_session uuid,_action text,_body jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare s taskfold_private.webhook_subscriptions;b taskfold_private.webhook_budgets;e taskfold_private.webhook_outbox;c taskfold_private.webhook_outbox;r taskfold_private.webhook_retry_receipts;
 rows jsonb:='[]';maximum int:=25;last_id uuid;more boolean:=false;n int:=0;
 pattern constant text:='^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$';
begin
 perform taskfold_private.automation_account_lock(_account);
 if exists(select 1 from taskfold_private.webhook_removal_blocks where user_id=_account) then raise exception using errcode='28000',message='Account access is unavailable';end if;
 perform 1 from auth.sessions where id=_session and user_id=_account and (not_after is null or not_after>clock_timestamp()) for key share;
 if not found then raise exception using errcode='28000',message='Sign in again';end if;
 if _body is null or jsonb_typeof(_body)<>'object' or octet_length(_body::text)>8192 or jsonb_typeof(_body->'id') is distinct from 'string' or (_body->>'id')!~pattern then raise exception using errcode='22023',message='Invalid delivery request';end if;
 select * into s from taskfold_private.webhook_subscriptions where id=(_body->>'id')::uuid and user_id=_account;
 if not found then raise exception using errcode='PT404',message='Webhook is unavailable';end if;
 if _action='history' then
  if exists(select 1 from jsonb_object_keys(_body) k where k not in('id','cursor','limit')) or (_body ? 'cursor' and (jsonb_typeof(_body->'cursor') is distinct from 'string' or (_body->>'cursor')!~pattern))
   or (_body ? 'limit' and (jsonb_typeof(_body->'limit') is distinct from 'number' or (_body->>'limit')::numeric not between 1 and 50 or (_body->>'limit')::numeric<>trunc((_body->>'limit')::numeric))) then raise exception using errcode='22023',message='Invalid delivery page';end if;
  if _body ? 'limit' then maximum=(_body->>'limit')::integer;end if;
  if _body ? 'cursor' then select * into c from taskfold_private.webhook_outbox where id=(_body->>'cursor')::uuid and subscription_id=s.id and user_id=_account;if not found then raise exception using errcode='PT404',message='Delivery page is unavailable';end if;end if;
  for e in select * from taskfold_private.webhook_outbox x where subscription_id=s.id and (c.id is null or (x.created_at,x.id)<(c.created_at,c.id)) order by x.created_at desc,x.id desc limit maximum+1 loop
   if n=maximum then more=true;exit;end if;rows=rows||jsonb_build_array(taskfold_private.webhook_event_receipt(e));last_id=e.id;n=n+1;
  end loop;
  return jsonb_build_object('account',_account,'subscription',taskfold_private.webhook_receipt(s),'events',rows,'next_cursor',case when more then last_id else null end);
 end if;
 if _action is null or _action<>'retry_delivery' or (select array_agg(k order by k) from jsonb_object_keys(_body) k) is distinct from array['event_id','id','request_id']
  or jsonb_typeof(_body->'event_id') is distinct from 'string' or (_body->>'event_id')!~pattern or jsonb_typeof(_body->'request_id') is distinct from 'string' or (_body->>'request_id')!~pattern then raise exception using errcode='22023',message='Invalid delivery retry';end if;
 select * into e from taskfold_private.webhook_outbox where id=(_body->>'event_id')::uuid and subscription_id=s.id and user_id=_account;
 if not found then raise exception using errcode='PT404',message='Delivery is unavailable';end if;
 select * into r from taskfold_private.webhook_retry_receipts where user_id=_account and request_id=(_body->>'request_id')::uuid;
 if found then
  if r.event_id<>e.id then raise exception using errcode='PT409',message='This retry belongs to another delivery';end if;
 else
  if s.scope='project' then perform taskfold_private.automation_lock_project(_account,s.project_id);end if;
  select * into s from taskfold_private.webhook_subscriptions where id=s.id for share;
  select * into b from taskfold_private.webhook_budgets where subscription_id=s.id for update;
  select * into e from taskfold_private.webhook_outbox where id=e.id for update;
  if s.state<>'active' or s.expires_at<=clock_timestamp() or b.blocked_reason is not null or e.status<>'failed' or e.payload is null or e.expires_at<=clock_timestamp() or e.manual_retries>=3 or b.pending>=256 then
   raise exception using errcode='PT409',message='Resume a current connection and review this delivery before retrying';end if;
  update taskfold_private.webhook_outbox set status='pending',finished_at=null,next_attempt_at=clock_timestamp(),part_attempts=0,manual_retries=manual_retries+1 where id=e.id returning * into e;
  update taskfold_private.webhook_budgets set pending=pending+1 where subscription_id=s.id;
  insert into taskfold_private.webhook_retry_receipts(user_id,request_id,event_id) values(_account,(_body->>'request_id')::uuid,e.id);
 end if;
 return jsonb_build_object('account',_account,'subscription',taskfold_private.webhook_receipt(s),'event',taskfold_private.webhook_event_receipt(e),'retry',jsonb_build_object('event_id',e.id,'request_id',_body->>'request_id','applied',true));
end$$;
revoke all on function taskfold_private.webhook_queue_native(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.webhook_queue_native(uuid,uuid,text,jsonb) to service_role;
create or replace function public.taskfold_webhooks(_account uuid,_session uuid,_action text,_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' set statement_timeout='10s' as $$begin
 if _action in('history','retry_delivery') then return taskfold_private.webhook_queue_native(_account,_session,_action,_body);end if;
 return taskfold_private.webhook_manage(_account,_session,_action,_body);
end$$;
