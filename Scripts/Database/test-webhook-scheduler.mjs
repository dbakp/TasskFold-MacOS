import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import { createHmac } from "node:crypto";
const db = new PGlite({ extensions: { pgcrypto } }), checks = {};
const value = async (sql, args = []) =>
  Object.values((await db.query(sql, args)).rows[0])[0];
const same = (name, a, b = true) => {
  assert.deepEqual(a, b, name);
  checks[name] = true;
};
try {
  await db.exec(
    `create schema extensions;create extension pgcrypto with schema extensions;create role anon;create role authenticated;create role service_role;
create schema taskfold_private;grant usage on schema taskfold_private to authenticated,service_role;
create schema cron;create schema net;create schema vault;
create table cron.job(jobid bigint generated always as identity,jobname text unique,schedule text,command text,active boolean default true);
create function cron.schedule(text,text,text) returns bigint language sql as $$insert into cron.job(jobname,schedule,command) values($1,$2,$3) returning jobid$$;
create function cron.alter_job(job_id bigint,active boolean) returns void language sql as $$update cron.job set active=$2 where jobid=$1$$;
create table vault.decrypted_secrets(name text,decrypted_secret text);
create table net.http_request_queue(id bigint);grant select on net.http_request_queue to public,anon,authenticated;
create table net._http_response(id bigint,status_code integer,timed_out boolean,created timestamptz);
create table net.fixture_requests(id bigint generated always as identity,url text,headers jsonb,body jsonb,timeout integer);
create function net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds integer) returns bigint language plpgsql as $$declare id bigint;begin
if current_setting('fixture.fail',true)='1' then raise exception 'Sensitive token: %',headers->>'Authorization';end if;
insert into net.fixture_requests(url,headers,body,timeout) values(url,headers,body,timeout_milliseconds) returning fixture_requests.id into id;return id;end$$;`,
  );
  await db.exec(
    await readFile(
      new URL(
        "../../supabase/migrations/20261023074744_webhook_scheduler.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  same(
    "migration-installs-disabled-job",
    await value(
      "select not active from cron.job where jobname='taskfold-webhook-dispatch'",
    ),
  );
  same(
    "minute-schedule",
    await value("select schedule from cron.job"),
    "* * * * *",
  );
  same(
    "cron-has-no-token-or-url",
    await value("select command from cron.job"),
    "select taskfold_private.invoke_webhook_worker();",
  );
  same(
    "disabled-does-not-enqueue",
    await value("select taskfold_private.invoke_webhook_worker()"),
    null,
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    same(
      role + "-cannot-invoke",
      await value(
        "select not has_function_privilege($1,'taskfold_private.invoke_webhook_worker()','execute')",
        [role],
      ),
    );
    same(
      role + "-cannot-configure",
      await value(
        "select not has_function_privilege($1,'taskfold_private.configure_webhook_scheduler(text,boolean)','execute')",
        [role],
      ),
    );
    same(
      role + "-cannot-read-state",
      await value(
        "select not has_table_privilege($1,'taskfold_private.webhook_scheduler','select')",
        [role],
      ),
    );
  }
  await assert.rejects(
    db.query(
      "select taskfold_private.configure_webhook_scheduler('aaaaaaaaaaaaaaaaaaaa',true)",
    ),
    /credential is unavailable/,
  );
  checks["missing-token-cannot-enable"] = true;
  await db.exec(
    "insert into vault.decrypted_secrets values('taskfold_webhook_worker_token','invalid')",
  );
  await assert.rejects(
    db.query(
      "select taskfold_private.configure_webhook_scheduler('aaaaaaaaaaaaaaaaaaaa',true)",
    ),
    /credential is unavailable/,
  );
  checks["invalid-token-cannot-enable"] = true;
  await db.query("update vault.decrypted_secrets set decrypted_secret=$1", [
    "1".repeat(64),
  ]);
  await assert.rejects(
    db.query(
      "select taskfold_private.configure_webhook_scheduler('https://evil.example',true)",
    ),
    /configuration is invalid/,
  );
  checks["arbitrary-url-rejected"] = true;
  await db.exec(
    "select taskfold_private.configure_webhook_scheduler('aaaaaaaaaaaaaaaaaaaa',true)",
  );
  same("explicit-enable-arms-job", await value("select active from cron.job"));
  same(
    "first-tick-enqueues",
    await value("select taskfold_private.invoke_webhook_worker()"),
    1,
  );
  same(
    "fixed-owned-dispatch-path",
    await value("select url from net.fixture_requests"),
    "https://aaaaaaaaaaaaaaaaaaaa.supabase.co/functions/v1/dispatch-webhooks",
  );
  same(
    "queue-has-short-lived-proof-not-worker-token",
    /^Taskfold-Schedule [0-9]{10}\.[a-f0-9-]{36}\.[a-f0-9]{64}$/.test(
      await value("select headers->>'Authorization' from net.fixture_requests"),
    ),
    true,
  );
  same(
    "empty-body-no-task-data",
    await value("select body from net.fixture_requests"),
    {},
  );
  same(
    "bounded-timeout",
    await value("select timeout from net.fixture_requests"),
    60000,
  );
  same(
    "repeat-tick-throttled",
    await value("select taskfold_private.invoke_webhook_worker()"),
    null,
  );
  await db.exec("insert into net._http_response values(1,200,false,now())");
  await value("select taskfold_private.invoke_webhook_worker()");
  same(
    "transport-health-recorded",
    await value(
      "select last_response_code from taskfold_private.webhook_scheduler",
    ),
    200,
  );
  await db.exec(
    "update taskfold_private.webhook_scheduler set last_queued_at=now()-interval '2 minutes';delete from vault.decrypted_secrets",
  );
  same(
    "missing-runtime-token-sends-nothing",
    await value("select taskfold_private.invoke_webhook_worker()"),
    null,
  );
  same(
    "configuration-loss-visible",
    await value("select last_state from taskfold_private.webhook_scheduler"),
    "unconfigured",
  );
  await db.query(
    "insert into vault.decrypted_secrets values('taskfold_webhook_worker_token',$1)",
    ["2".repeat(64)],
  );
  same(
    "next-tick-recovers",
    await value("select taskfold_private.invoke_webhook_worker()"),
    2,
  );
  const auth = await value(
    "select headers->>'Authorization' from net.fixture_requests where id=2",
  );
  const [issued, nonce, proof] = auth.slice("Taskfold-Schedule ".length).split(
    ".",
  );
  same(
    "rotation-uses-current-vault-token",
    proof,
    createHmac("sha256", "2".repeat(64)).update(
      `taskfold.webhook.schedule.v1.${issued}.${nonce}.aaaaaaaaaaaaaaaaaaaa`,
    ).digest("hex"),
  );
  same("reusable-token-never-in-request", !auth.includes("2".repeat(64)));
  same(
    "first-scheduled-admission",
    await value("select public.taskfold_webhook_schedule_admit($1,$2)", [
      nonce,
      Number(issued),
    ]),
  );
  same(
    "replayed-admission-rejected",
    await value("select public.taskfold_webhook_schedule_admit($1,$2)", [
      nonce,
      Number(issued),
    ]),
    false,
  );
  same(
    "wrong-nonce-rejected",
    await value(
      "select public.taskfold_webhook_schedule_admit(gen_random_uuid(),$1)",
      [Number(issued)],
    ),
    false,
  );
  await db.query(
    "update taskfold_private.webhook_scheduler set scheduled_issued=$1,consumed_at=null",
    [Number(issued) - 100],
  );
  same(
    "expired-admission-rejected",
    await value("select public.taskfold_webhook_schedule_admit($1,$2)", [
      nonce,
      Number(issued) - 100,
    ]),
    false,
  );
  await db.query(
    "update taskfold_private.webhook_scheduler set scheduled_issued=$1,consumed_at=null",
    [Number(issued) + 30],
  );
  same(
    "future-admission-rejected",
    await value("select public.taskfold_webhook_schedule_admit($1,$2)", [
      nonce,
      Number(issued) + 30,
    ]),
    false,
  );
  same(
    "native-role-cannot-admit",
    await value(
      "select not has_function_privilege('authenticated','public.taskfold_webhook_schedule_admit(uuid,bigint)','execute')",
    ),
  );
  await db.exec(
    "update taskfold_private.webhook_scheduler set consumed_at=null;select taskfold_private.configure_webhook_scheduler(null,false)",
  );
  same(
    "disable-invalidates-queued-proof",
    await value(
      "select scheduled_nonce is null from taskfold_private.webhook_scheduler",
    ),
  );
  await db.exec(
    "select taskfold_private.configure_webhook_scheduler('aaaaaaaaaaaaaaaaaaaa',true)",
  );
  same(
    "reenable-cannot-revive-old-proof",
    await value("select public.taskfold_webhook_schedule_admit($1,$2)", [
      nonce,
      Number(issued),
    ]),
    false,
  );
  await db.exec(
    "update taskfold_private.webhook_scheduler set last_queued_at=now()-interval '2 minutes';set fixture.fail='1'",
  );
  same(
    "enqueue-error-does-not-leak",
    await value("select taskfold_private.invoke_webhook_worker()"),
    null,
  );
  same(
    "enqueue-error-visible-without-message",
    await value("select last_state from taskfold_private.webhook_scheduler"),
    "enqueue_failed",
  );
  await db.exec(
    "delete from vault.decrypted_secrets;select taskfold_private.configure_webhook_scheduler(null,false)",
  );
  same(
    "disable-needs-no-token",
    await value("select not active from cron.job"),
  );
  same(
    "disabled-after-config-loss",
    await value("select taskfold_private.invoke_webhook_worker()"),
    null,
  );
  same(
    "only-two-requests-recorded",
    await value("select count(*)::integer from net.fixture_requests"),
    2,
  );
  const result = {
    date: new Date().toISOString(),
    checks,
    passed: true,
    scope:
      "Actual scheduler migration with local cron/net/Vault stubs; not hosted delivery",
    realTasksChanged: 0,
  };
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(result, null, 2) + "\n");
  }
  console.log(
    JSON.stringify({ passed: true, checks: Object.keys(checks).length }),
  );
} finally {
  await db.close();
}
