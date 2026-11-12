-- Taskfold hosted acceptance: automation API + webhook queue, database layer.
--
--   supabase db query --remote -f Scripts/automation_hosted_acceptance.sql
--
-- (or run Scripts/automation_hosted_acceptance.sh, which also checks the deployed
-- functions and the transport code). Everything happens inside ONE transaction that
-- ends in ROLLBACK, so the fixture users, sessions, keys, tasks, webhook subscription,
-- outbox rows and request counters are deleted atomically; an assertion failure aborts
-- the script, which also rolls everything back. No password, JWT or real token is used:
-- the fixture API token is an inert constant and only its SHA-256 is ever stored.
-- The RPCs are the exact ones the edge functions call, run as `service_role`.
-- Output: a final single row "ACCEPTANCE PASSED" when every check held.
begin;
set local timezone = 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';
create function pg_temp.require(ok boolean, label text) returns void language plpgsql as $$begin
 if ok is distinct from true then raise exception 'ACCEPTANCE FAILED: %', label; end if;
end$$;

-- ---------------------------------------------------------------- fixtures
-- Account A owns everything; account B proves isolation. Fixed ids make cleanup
-- unnecessary beyond the rollback, and the example.invalid domain can never receive mail.
insert into auth.users(id, email) values
 ('f0acce55-0000-4000-8000-0000000000a1', 'taskfold-acceptance-a@example.invalid'),
 ('f0acce55-0000-4000-8000-0000000000b1', 'taskfold-acceptance-b@example.invalid');
insert into auth.sessions(id, user_id) values
 ('f0acce55-0000-4000-8000-0000000000a2', 'f0acce55-0000-4000-8000-0000000000a1'),
 ('f0acce55-0000-4000-8000-0000000000b2', 'f0acce55-0000-4000-8000-0000000000b1');
-- Hashes of inert fixture tokens, exactly what a client would send (SHA-256 of the token).
select set_config('acc.h_full', encode(extensions.digest('tfk_v1_f0acce5500004000800000000000c001_' || repeat('A', 43), 'sha256'), 'hex'), true),
       set_config('acc.h_read', encode(extensions.digest('tfk_v1_f0acce5500004000800000000000c002_' || repeat('B', 43), 'sha256'), 'hex'), true),
       set_config('acc.h_exp', encode(extensions.digest('tfk_v1_f0acce5500004000800000000000c003_' || repeat('C', 43), 'sha256'), 'hex'), true),
       set_config('acc.h_other', encode(extensions.digest('tfk_v1_f0acce5500004000800000000000c0b1_' || repeat('D', 43), 'sha256'), 'hex'), true),
       set_config('acc.h_wrong', encode(extensions.digest('tfk_v1_f0acce5500004000800000000000c001_' || repeat('Z', 43), 'sha256'), 'hex'), true);
-- A verified, active webhook subscription for A (scope all). The envelope is a shape-valid
-- placeholder: this layer never decrypts it, and the transaction never reaches a receiver.
insert into taskfold_private.webhook_subscriptions(id, user_id, name, endpoint, scope, events, ttl_days, secret_hash, secret_envelope, state, created_at, expires_at, verified_at)
values ('f0acce55-0000-4000-8000-0000000000d1', 'f0acce55-0000-4000-8000-0000000000a1', 'Acceptance receiver',
 'https://hooks.example.invalid/taskfold', 'all',
 array['task.created', 'task.updated', 'task.completed', 'task.reopened', 'task.deleted'], 30, repeat('0', 64),
 jsonb_build_object('version', 1, 'keyVersion', 'v1', 'nonce', repeat('A', 16), 'ciphertext', repeat('A', 64)),
 'active', clock_timestamp(), clock_timestamp() + interval '30 days', clock_timestamp());
-- Claims are global: only run the dispatch walk-through when no other live subscription exists.
select set_config('acc.claim', case when exists(select 1 from taskfold_private.webhook_subscriptions
  where id <> 'f0acce55-0000-4000-8000-0000000000d1' and state = 'active') then 'no' else 'yes' end, true);

-- ------------------------------------------------ keys, tasks, scopes (service role)
set local role service_role;
do $$
declare
 a uuid := 'f0acce55-0000-4000-8000-0000000000a1'; sa uuid := 'f0acce55-0000-4000-8000-0000000000a2';
 b uuid := 'f0acce55-0000-4000-8000-0000000000b1'; sb uuid := 'f0acce55-0000-4000-8000-0000000000b2';
 k_full uuid := 'f0acce55-0000-4000-8000-00000000c001'; k_read uuid := 'f0acce55-0000-4000-8000-00000000c002';
 k_exp uuid := 'f0acce55-0000-4000-8000-00000000c003'; k_other uuid := 'f0acce55-0000-4000-8000-00000000c0b1';
 h_full text := current_setting('acc.h_full'); h_read text := current_setting('acc.h_read');
 h_other text := current_setting('acc.h_other'); h_wrong text := current_setting('acc.h_wrong');
 t1 uuid := 'f0acce55-0000-4000-8000-00000000e001'; t2 uuid := 'f0acce55-0000-4000-8000-00000000e002';
 g1 uuid := 'f0acce55-0000-4000-8000-00000000f001'; g2 uuid := 'f0acce55-0000-4000-8000-00000000f002';
 r jsonb; task jsonb; base jsonb; i integer; ok boolean;
begin
 -- Key management (what automation-keys calls). Raw secrets never reach SQL: only hashes.
 perform public.taskfold_automation_keys(a, sa, 'create', jsonb_build_object('id', k_full, 'name', 'Acceptance full', 'token_hash', h_full,
  'scopes', jsonb_build_array('tasks:read', 'tasks:create', 'tasks:complete'), 'ttl_days', 7));
 perform public.taskfold_automation_keys(a, sa, 'create', jsonb_build_object('id', k_read, 'name', 'Acceptance read only', 'token_hash', h_read,
  'scopes', jsonb_build_array('tasks:read'), 'ttl_days', 7));
 perform public.taskfold_automation_keys(a, sa, 'create', jsonb_build_object('id', k_exp, 'name', 'Acceptance expiring', 'token_hash', current_setting('acc.h_exp'),
  'scopes', jsonb_build_array('tasks:read'), 'ttl_days', 7));
 perform public.taskfold_automation_keys(b, sb, 'create', jsonb_build_object('id', k_other, 'name', 'Acceptance other account', 'token_hash', h_other,
  'scopes', jsonb_build_array('tasks:read', 'tasks:create', 'tasks:complete'), 'ttl_days', 7));
 r := public.taskfold_automation_keys(a, sa, 'list', '{}');
 if jsonb_array_length(r->'keys') <> 3 or r->'keys'->0 ? 'token_hash' then raise exception 'ACCEPTANCE FAILED: key list shape'; end if;
 -- A foreign session cannot manage A's keys.
 begin perform public.taskfold_automation_keys(a, sb, 'list', '{}'); raise exception 'ACCEPTANCE FAILED: foreign session accepted';
 exception when invalid_authorization_specification then null; end;

 -- list (tasks:read): empty, then bounded-input validation.
 r := public.taskfold_automation_read(k_full, h_full, 'list', '{}');
 if r->'tasks' <> '[]'::jsonb or r->'next_cursor' <> 'null'::jsonb then raise exception 'ACCEPTANCE FAILED: new account should list no tasks'; end if;
 begin perform public.taskfold_automation_read(k_full, h_full, 'list', '{"limit":51}'); raise exception 'ACCEPTANCE FAILED: oversized page accepted';
 exception when invalid_parameter_value then null; end;

 -- create (tasks:create) + exact replay.
 task := jsonb_build_object('id', t1, 'request_id', 'f0acce55-0000-4000-8000-00000000a001', 'task_generation', g1, 'time_zone', 'UTC',
  'fields', jsonb_build_object('title', 'Taskfold acceptance fixture task', 'priority', 2));
 r := public.taskfold_automation_write(k_full, h_full, 'create', task);
 if (r->>'replayed')::boolean or r->'receipt'->>'operation' <> 'create' or r->'receipt'->>'task_id' <> t1::text then raise exception 'ACCEPTANCE FAILED: create receipt'; end if;
 r := public.taskfold_automation_write(k_full, h_full, 'create', task);
 if not (r->>'replayed')::boolean then raise exception 'ACCEPTANCE FAILED: replay not detected'; end if;
 begin perform public.taskfold_automation_write(k_full, h_full, 'create', jsonb_set(task, '{fields,title}', '"changed"'));
  raise exception 'ACCEPTANCE FAILED: reused request id accepted';
 exception when sqlstate 'PT409' then null; end;

 -- get + list now see the task; completion baseline comes from the reviewed read.
 r := public.taskfold_automation_read(k_full, h_full, 'get', jsonb_build_object('id', t1));
 task := r->'task';
 if task->>'title' <> 'Taskfold acceptance fixture task' or (task->>'completed')::boolean or task->>'revision' !~ '^[0-9a-f]{64}$' or (task->>'user_id')::uuid <> a then raise exception 'ACCEPTANCE FAILED: get projection'; end if;
 r := public.taskfold_automation_read(k_full, h_full, 'list', '{"completed":false}');
 if jsonb_array_length(r->'tasks') <> 1 then raise exception 'ACCEPTANCE FAILED: list should show the fixture task'; end if;

 -- complete (tasks:complete) with the reviewed baseline; stale baseline is refused.
 base := jsonb_build_object('task_generation', task->>'task_generation', 'completed', (task->>'completed')::boolean,
  'completed_at', task->'completed_at', 'completion_version', (task->>'completion_version')::bigint);
 r := public.taskfold_automation_write(k_full, h_full, 'complete', jsonb_build_object('id', t1, 'request_id', 'f0acce55-0000-4000-8000-00000000a002',
  'task_generation', g1, 'time_zone', 'UTC', 'base', base));
 if r->'receipt'->>'operation' <> 'complete' or (r->>'replayed')::boolean then raise exception 'ACCEPTANCE FAILED: complete receipt'; end if;
 r := public.taskfold_automation_read(k_full, h_full, 'get', jsonb_build_object('id', t1));
 if not (r->'task'->>'completed')::boolean then raise exception 'ACCEPTANCE FAILED: task not completed'; end if;
 r := public.taskfold_automation_read(k_full, h_full, 'list', '{"completed":true}');
 if jsonb_array_length(r->'tasks') <> 1 then raise exception 'ACCEPTANCE FAILED: completed filter'; end if;
 begin perform public.taskfold_automation_write(k_full, h_full, 'complete', jsonb_build_object('id', t1, 'request_id', 'f0acce55-0000-4000-8000-00000000a003',
   'task_generation', g1, 'time_zone', 'UTC', 'base', base));
  raise exception 'ACCEPTANCE FAILED: stale completion baseline accepted';
 exception when sqlstate 'PT409' then null; end;

 -- Scopes: a read-only key cannot create; the full key has no update/delete scope.
 begin perform public.taskfold_automation_write(k_read, h_read, 'create', jsonb_build_object('id', t2, 'request_id', 'f0acce55-0000-4000-8000-00000000a004',
   'task_generation', g2, 'time_zone', 'UTC', 'fields', jsonb_build_object('title', 'must not exist')));
  raise exception 'ACCEPTANCE FAILED: read-only key created a task';
 exception when insufficient_privilege then null; end;
 begin perform public.taskfold_automation_write(k_full, h_full, 'update', jsonb_build_object('id', t1, 'request_id', 'f0acce55-0000-4000-8000-00000000a005',
   'task_generation', g1, 'time_zone', 'UTC', 'base', jsonb_build_object('task_generation', g1), 'fields', jsonb_build_object('title', 'nope')));
  raise exception 'ACCEPTANCE FAILED: key without update scope updated a task';
 exception when insufficient_privilege then null; end;

 -- Wrong, unknown and malformed credentials are refused (same error, no oracle).
 foreach ok in array array[true, false] loop
  begin
   if ok then perform public.taskfold_automation_read(k_full, h_wrong, 'list', '{}');
   else perform public.taskfold_automation_read('f0acce55-0000-4000-8000-00000000dead', h_full, 'list', '{}'); end if;
   raise exception 'ACCEPTANCE FAILED: bad credential accepted';
  exception when invalid_authorization_specification then null; end;
 end loop;
 begin perform public.taskfold_automation_read(k_full, 'not-a-hash', 'list', '{}'); raise exception 'ACCEPTANCE FAILED: malformed hash accepted';
 exception when invalid_authorization_specification then null; end;

 -- Revocation takes effect immediately (read-only key before and after).
 perform public.taskfold_automation_read(k_read, h_read, 'list', '{}');
 r := public.taskfold_automation_keys(a, sa, 'revoke', jsonb_build_object('id', k_read));
 if r->'key'->>'revoked_at' is null then raise exception 'ACCEPTANCE FAILED: revoke receipt'; end if;
 begin perform public.taskfold_automation_read(k_read, h_read, 'list', '{}'); raise exception 'ACCEPTANCE FAILED: revoked key accepted';
 exception when invalid_authorization_specification then null; end;

 -- Account isolation: B's valid key cannot read, nor complete, A's task.
 begin perform public.taskfold_automation_read(k_other, h_other, 'get', jsonb_build_object('id', t1)); raise exception 'ACCEPTANCE FAILED: cross-account read';
 exception when sqlstate 'PT404' then null; end;
 r := public.taskfold_automation_read(k_other, h_other, 'list', '{}');
 if r->'tasks' <> '[]'::jsonb then raise exception 'ACCEPTANCE FAILED: B can list A tasks'; end if;
 begin perform public.taskfold_automation_write(k_other, h_other, 'complete', jsonb_build_object('id', t1, 'request_id', 'f0acce55-0000-4000-8000-00000000a006',
   'task_generation', g1, 'time_zone', 'UTC', 'base', jsonb_set(base, '{completed}', 'true')));
  raise exception 'ACCEPTANCE FAILED: cross-account write';
 exception when sqlstate 'PT404' or sqlstate 'PT409' then null; end;

 -- Body bounds at the database layer: an over-long title is refused.
 begin perform public.taskfold_automation_write(k_full, h_full, 'create', jsonb_build_object('id', t2, 'request_id', 'f0acce55-0000-4000-8000-00000000a007',
   'task_generation', g2, 'time_zone', 'UTC', 'fields', jsonb_build_object('title', repeat('x', 8193))));
  raise exception 'ACCEPTANCE FAILED: oversized title accepted';
 exception when invalid_parameter_value then null; end;

 -- A second task so the webhook queue has a creation to capture after the subscription exists.
 perform public.taskfold_automation_write(k_full, h_full, 'create', jsonb_build_object('id', t2, 'request_id', 'f0acce55-0000-4000-8000-00000000a008',
  'task_generation', g2, 'time_zone', 'UTC', 'fields', jsonb_build_object('title', 'Second acceptance task')));

 -- Ingress admission (the per-IP/credential/global budget in front of the functions).
 for i in 1..60 loop
  r := public.taskfold_automation_admit('keys', repeat('a', 64), repeat('b', 64));
  if not (r->>'allowed')::boolean then raise exception 'ACCEPTANCE FAILED: admission denied before its budget (call %, by %)', i, r->>'limited_by'; end if;
 end loop;
 r := public.taskfold_automation_admit('keys', repeat('a', 64), repeat('b', 64));
 if (r->>'allowed')::boolean or r->>'limited_by' not in ('ip', 'credential', 'global') or (r->>'retry_after')::int not between 1 and 60 then raise exception 'ACCEPTANCE FAILED: ingress budget not enforced'; end if;
end$$;
reset role;

-- -------------------------------------------------- state checks as the database owner
do $$
declare a uuid := 'f0acce55-0000-4000-8000-0000000000a1'; n integer; types text[];
begin
 -- Only hashes are stored, and they are not the token material.
 perform pg_temp.require((select count(*) = 4 and bool_and(token_hash ~ '^[0-9a-f]{64}$') from taskfold_private.automation_keys where user_id in (a, 'f0acce55-0000-4000-8000-0000000000b1')), 'keys store 64-hex hashes only');
 perform pg_temp.require((select not exists(select 1 from taskfold_private.automation_keys where token_hash like 'tfk\_v1\_%')), 'no raw token stored');
 perform pg_temp.require((select last_used_at is not null and day_requests >= 1 from taskfold_private.automation_keys where id = 'f0acce55-0000-4000-8000-00000000c001'), 'usage is metered per key');
 -- Expiry: age the fixture key past its end, then it must stop working (checked next).
 update taskfold_private.automation_keys set expires_at = clock_timestamp() - interval '1 second' where id = 'f0acce55-0000-4000-8000-00000000c003';
 -- Webhook capture: creation and completion of the fixture tasks were queued durably.
 select array_agg(distinct event_type) into types from taskfold_private.webhook_outbox where subscription_id = 'f0acce55-0000-4000-8000-0000000000d1';
 perform pg_temp.require(types @> array['task.created', 'task.completed', 'task.updated'], 'task events are captured for the subscription');
 select count(*) into n from taskfold_private.webhook_outbox where subscription_id = 'f0acce55-0000-4000-8000-0000000000d1' and event_type = 'task.created';
 perform pg_temp.require(n = 2, 'one created event per task');
 perform pg_temp.require((select bool_and(payload::jsonb->>'version' = '1' and payload::jsonb->>'type' = event_type and (payload::jsonb->>'event_id')::uuid = id
   and payload_sha256 = encode(extensions.digest(convert_to(payload, 'UTF8'), 'sha256'), 'hex') and status = 'pending')
  from taskfold_private.webhook_outbox where subscription_id = 'f0acce55-0000-4000-8000-0000000000d1'), 'queued payloads are versioned, hashed and pending');
 perform pg_temp.require((select pending = (select count(*) from taskfold_private.webhook_outbox where subscription_id = 'f0acce55-0000-4000-8000-0000000000d1') from taskfold_private.webhook_budgets where subscription_id = 'f0acce55-0000-4000-8000-0000000000d1'), 'queue budget matches queued events');
end$$;

set local role service_role;
do $$
declare
 k_exp uuid := 'f0acce55-0000-4000-8000-00000000c003'; c jsonb; p jsonb; ack jsonb; body jsonb;
begin
 begin perform public.taskfold_automation_read(k_exp, current_setting('acc.h_exp'), 'list', '{}'); raise exception 'ACCEPTANCE FAILED: expired key accepted';
 exception when invalid_authorization_specification then null; end;

 -- Dispatch walk-through (what dispatch-webhooks drives): claim -> prepare -> authorize -> ack.
 if current_setting('acc.claim') <> 'yes' then
  raise notice 'Skipped claim/prepare/ack: other active webhook subscriptions exist, so a claim could pick their event.';
  return;
 end if;
 c := public.taskfold_webhook_dispatch('claim', '{}');
 if c->>'event_id' is null then raise exception 'ACCEPTANCE FAILED: nothing to claim'; end if;
 p := public.taskfold_webhook_dispatch('prepare', jsonb_build_object('event_id', c->'event_id', 'lease_id', c->'lease_id'));
 body := (p->>'body')::jsonb;
 if not (p->>'ready')::boolean or p->>'endpoint' <> 'https://hooks.example.invalid/taskfold' or p->>'subscription_id' <> 'f0acce55-0000-4000-8000-0000000000d1'
  or body->>'version' <> '1' or body->>'type' <> 'task.created' or body->>'event_id' <> c->>'event_id'
  or body->'task'->>'id' <> 'f0acce55-0000-4000-8000-00000000e001' or p->'secret_envelope'->>'keyVersion' <> 'v1' then
  raise exception 'ACCEPTANCE FAILED: prepared packet';
 end if;
 -- The raw task is complete but the packet must not leak the receiver secret hash or other accounts.
 if p::text like '%secret_hash%' then raise exception 'ACCEPTANCE FAILED: packet exposes secret hash'; end if;
 p := public.taskfold_webhook_dispatch('authorize', jsonb_build_object('event_id', c->'event_id', 'lease_id', c->'lease_id'));
 if not (p->>'ready')::boolean then raise exception 'ACCEPTANCE FAILED: authorize'; end if;
 ack := public.taskfold_webhook_dispatch('ack', jsonb_build_object('event_id', c->'event_id', 'lease_id', c->'lease_id', 'outcome', 'delivered', 'status', 200));
 if not (ack->>'applied')::boolean then raise exception 'ACCEPTANCE FAILED: ack'; end if;
 -- Replaying the same ack must not apply twice (the lease is gone).
 ack := public.taskfold_webhook_dispatch('ack', jsonb_build_object('event_id', c->'event_id', 'lease_id', c->'lease_id', 'outcome', 'delivered', 'status', 200));
 if (ack->>'applied')::boolean then raise exception 'ACCEPTANCE FAILED: ack replay applied'; end if;
 perform set_config('acc.event', c->>'event_id', true);
end$$;
reset role;

do $$
declare r text;
begin
 if nullif(current_setting('acc.event', true), '') is not null then
  perform pg_temp.require((select status = 'delivered' and payload is null and http_status = 200 from taskfold_private.webhook_outbox where id = current_setting('acc.event')::uuid), 'delivered event is final and its payload is purged');
 end if;
 -- Privilege boundaries: clients and the service role reach nothing but the fixed RPCs.
 foreach r in array array['anon', 'authenticated', 'service_role'] loop
  perform pg_temp.require(not has_table_privilege(r, 'taskfold_private.automation_keys', 'select'), r || ' cannot read keys');
  perform pg_temp.require(not has_table_privilege(r, 'taskfold_private.webhook_subscriptions', 'select'), r || ' cannot read subscriptions');
  perform pg_temp.require(not has_table_privilege(r, 'taskfold_private.webhook_outbox', 'select'), r || ' cannot read the outbox');
  perform pg_temp.require(not has_table_privilege(r, 'taskfold_private.webhook_scheduler', 'select'), r || ' cannot read the scheduler row');
  perform pg_temp.require(not has_function_privilege(r, 'taskfold_private.automation_authorize(uuid,text,text)', 'execute'), r || ' cannot call the authorize helper');
  perform pg_temp.require(not has_function_privilege(r, 'taskfold_private.configure_webhook_scheduler(text,boolean)', 'execute'), r || ' cannot configure the scheduler');
  perform pg_temp.require(not has_function_privilege(r, 'taskfold_private.invoke_webhook_worker()', 'execute'), r || ' cannot invoke the worker');
 end loop;
 foreach r in array array['anon', 'authenticated'] loop
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_automation_read(uuid,text,text,jsonb)', 'execute'), r || ' cannot call task read');
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_automation_write(uuid,text,text,jsonb)', 'execute'), r || ' cannot call task write');
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_automation_keys(uuid,uuid,text,jsonb)', 'execute'), r || ' cannot manage keys');
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_webhook_dispatch(text,jsonb)', 'execute'), r || ' cannot dispatch');
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_webhooks(uuid,uuid,text,jsonb)', 'execute'), r || ' cannot manage webhooks');
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_webhook_schedule_admit(uuid,bigint)', 'execute'), r || ' cannot admit schedules');
 end loop;
end$$;

-- Delete every fixture: users, keys, tasks, webhook rows and counters all go with the transaction.
rollback;
-- Reaching this point means every assertion above held and nothing was persisted.
select 'ACCEPTANCE PASSED' as result,
 not exists(select 1 from auth.users where email like 'taskfold-acceptance-%@example.invalid') as fixtures_removed;
