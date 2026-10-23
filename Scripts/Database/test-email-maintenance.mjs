import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import {
  createPostgresFixture,
  literal as lit,
  postgresImage,
} from "./postgres-fixture.mjs";
import { loadEmailIntakeSchema } from "./email-intake-schema.mjs";
const migration = "20261023182542_email_inactive_maintenance.sql";
const summary = {
  date: new Date().toISOString(),
  image: postgresImage,
  checks: {},
  hostedAcceptance: false,
  cron: "SQL scheduling contract shim; actual pg_cron timer not exercised",
};
const id = (n) => "f0e5cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const hash = (n) =>
  createHash("sha256").update("maintenance-" + n).digest("hex");
const doc = (x) => lit(JSON.stringify(x)) + "::jsonb";
let pg;
const same = (name, a, b = true) => {
  summary.checks[name] = false;
  assert.deepEqual(a, b, name);
  summary.checks[name] = true;
};
const scalar = (q) => pg.scalar(q);
async function run() {
  const r = await pg.value("taskfold_private.run_email_maintenance()", {
    role: "postgres",
  });
  assert.equal(r.code, null, r.reason);
  return r.value;
}
async function reset() {
  await pg.raw(
    "truncate taskfold_private.email_deliveries,taskfold_private.email_routes,taskfold_private.email_route_cancellations;update taskfold_private.email_maintenance set after_account=null,last_counts='{}',last_run_at=null",
  );
}
async function route(n, owner = 1, state = "active", age = 0) {
  await pg.raw(
    `insert into taskfold_private.email_routes(id,user_id,name,alias_hash,sender_email,requested_at,state,updated_at,alias_domain)values(${
      lit(id(n))
    },${lit(id(owner))},'Synthetic retention route',${
      lit(hash(n))
    },'maintenance@example.invalid',now(),${
      lit(state)
    },now()-interval '${age} days','mail.example.invalid')`,
  );
}
async function receipts(routeId, count, created = 31, received = 31) {
  await pg.raw(
    `insert into taskfold_private.email_deliveries(route_id,user_id,delivery_key,content_fingerprint,received_at,task_id,task_generation,created_at)select ${
      lit(id(routeId))
    },user_id,md5(n::text)||md5(('retention-'||n)::text),repeat('a',64),now()-interval '${received} days',gen_random_uuid(),gen_random_uuid(),now()-interval '${created} days' from taskfold_private.email_routes cross join generate_series(1,${count}) n where id=${
      lit(id(routeId))
    }`,
  );
}
async function cancels(owner, count, age = 31) {
  await pg.raw(
    `insert into taskfold_private.email_route_cancellations(id,user_id,created_at)select gen_random_uuid(),${
      lit(id(owner))
    },now()-interval '${age} days' from generate_series(1,${count})`,
  );
}
try {
  pg = await createPostgresFixture({ advisors: true });
  summary.postgresVersion = pg.serverVersion;
  await loadEmailIntakeSchema(pg.raw);
  await pg.raw(
    `create schema cron;create table cron.job(jobid bigint generated always as identity primary key,jobname text unique,schedule text,command text,active boolean default true);
 create function cron.schedule(text,text,text) returns bigint language sql as $$insert into cron.job(jobname,schedule,command)values($1,$2,$3)on conflict(jobname)do update set schedule=$2,command=$3 returning jobid$$;
 create function cron.alter_job(job_id bigint,active boolean)returns void language sql as $$update cron.job set active=$2 where jobid=$1$$;`,
  );
  await pg.raw(
    await readFile(
      new URL("../../supabase/migrations/" + migration, import.meta.url),
      "utf8",
    ),
  );
  same(
    "installed inactive",
    await scalar(
      "select to_jsonb(not active) from cron.job where jobname='taskfold-email-maintenance'",
    ),
  );
  same(
    "bounded five minute schedule",
    await scalar("select to_jsonb(schedule) from cron.job"),
    "*/5 * * * *",
  );
  const command = await scalar("select to_jsonb(command) from cron.job");
  same(
    "cron deadline precedes invocation",
    command,
    "set statement_timeout='20s'; set lock_timeout='250ms'; select taskfold_private.run_email_maintenance();",
  );
  same("disabled invocation", await run(), { state: "disabled" });
  for (const role of ["anon", "authenticated", "service_role"]) {
    for (
      const fn of [
        "run_email_maintenance()",
        "configure_email_maintenance(boolean)",
        "email_maintenance_accounts(uuid,timestamptz)",
      ]
    ) {
      same(
        role + " cannot execute " + fn,
        await scalar(
          `select to_jsonb(not has_function_privilege(${lit(role)},${
            lit("taskfold_private." + fn)
          },'execute'))`,
        ),
      );
    }
    same(
      role + " cannot read private state",
      await scalar(
        `select to_jsonb(not has_table_privilege(${
          lit(role)
        },'taskfold_private.email_maintenance','select'))`,
      ),
    );
    try {
      await pg.raw(
        `set role ${role};select taskfold_private.run_email_maintenance()`,
      );
      assert.fail("Unexpected allowed role");
    } catch (e) {
      same(role + " actual invocation denied", e.code, "42501");
    }
  }
  try {
    await pg.raw("select taskfold_private.configure_email_maintenance(null)");
    assert.fail("Allowed null");
  } catch (e) {
    same("null enable refused", e.code, "P0001");
  }
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at)select ('f0e5cafe-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'maintenance'||n||'@example.invalid',now() from generate_series(1,27)n;
 insert into auth.sessions(id,user_id) values(${lit(id(100))},${
      lit(id(1))
    });insert into public.profiles(user_id)values(${lit(id(1))});
 update auth.users set email='maintenance@example.invalid' where id=${
      lit(id(1))
    };
 update taskfold_private.email_intake_config set enabled=true,provider='synthetic-adapter',domain='mail.example.invalid';
 select taskfold_private.configure_email_maintenance(true);`,
  );
  same(
    "operator enables both scheduler and worker",
    await scalar(
      "select to_jsonb(j.active and s.enabled) from cron.job j cross join taskfold_private.email_maintenance s",
    ),
  );
  // Genuine task creation first, then age only receipt metadata as a retention fixture.
  const body = {
    id: id(101),
    name: "Original delivery",
    alias_hash: hash(101),
    project_id: null,
    requested_at: new Date().toISOString(),
    domain: "mail.example.invalid",
  };
  let r = await pg.value(
    `public.taskfold_email_routes(${lit(id(1))},${lit(id(100))},'create',${
      doc(body)
    })`,
  );
  same("real route setup succeeds", r.code, null);
  const content = {
    title: "Retain my task",
    description: "Complete synthetic mail body",
    attachmentCount: 0,
  };
  const delivery = (time) =>
    `public.taskfold_email_deliver_v2(${
      lit(hash(101))
    },'mail.example.invalid','synthetic-adapter','original-receipt',${time},'maintenance@example.invalid',${
      doc(content)
    })`;
  r = await pg.value(delivery("clock_timestamp()"));
  same("real delivery succeeds", r.code, null);
  const tasks = await scalar(
    "select coalesce(jsonb_agg(to_jsonb(t)order by id),'[]') from public.tasks t",
  );
  await pg.raw(
    "update taskfold_private.email_deliveries set created_at=now()-interval '31 days',received_at=now()-interval '31 days'",
  );
  same("inactive receipt removed", (await run()).deliveries, 1);
  r = await pg.value(delivery("now()-interval '31 days'"));
  same("ancient delivery after pruning refused", r.code, "22023");
  same(
    "pruning never changes saved task",
    await scalar(
      "select coalesce(jsonb_agg(to_jsonb(t)order by id),'[]') from public.tasks t",
    ),
    tasks,
  );
  await reset();
  await route(102);
  await receipts(102, 1, 31, 1);
  await route(103);
  await receipts(103, 1, 1, 31);
  await route(104, 1, "paused");
  await receipts(104, 1, 31, 31);
  same("both receipt clocks must expire", (await run()).deliveries, 1);
  same(
    "fresh-created and fresh-received receipts retained",
    await scalar(
      "select to_jsonb(count(*)) from taskfold_private.email_deliveries",
    ),
    2,
  );
  same(
    "active and paused routes retained",
    await scalar(
      "select to_jsonb(count(*)) from taskfold_private.email_routes",
    ),
    3,
  );
  await reset();
  await route(105, 1, "revoked", 31);
  await receipts(105, 1, 31, 1);
  await route(106, 1, "revoked", 31);
  await route(107, 1, "revoked", 1);
  await cancels(1, 1, 1);
  await cancels(1, 1, 31);
  r = await run();
  same("old empty revoked route pruned", r.routes, 1);
  same("old cancellation pruned", r.cancellations, 1);
  same(
    "revoked route with receipt retained",
    await scalar(
      `select to_jsonb(count(*)) from taskfold_private.email_routes where id=${
        lit(id(105))
      }`,
    ),
    1,
  );
  same(
    "recent revoked route retained",
    await scalar(
      `select to_jsonb(count(*)) from taskfold_private.email_routes where id=${
        lit(id(107))
      }`,
    ),
    1,
  );
  same(
    "recent cancellation retained",
    await scalar(
      "select to_jsonb(count(*)) from taskfold_private.email_route_cancellations",
    ),
    1,
  );
  await pg.raw(
    `insert into taskfold_private.email_route_cancellations(id,user_id,created_at) values(${
      lit(id(109))
    },${lit(id(1))},now()-interval '31 days')`,
  );
  same("expired setup cancellation removed", (await run()).cancellations, 1);
  const ancient = {
    ...body,
    id: id(109),
    alias_hash: hash(109),
    requested_at: new Date(Date.now() - 31 * 86400000).toISOString(),
  };
  const ancientResult = await pg.value(
    `public.taskfold_email_routes(${lit(id(1))},${lit(id(100))},'create',${
      doc(ancient)
    })`,
  );
  same(
    "unchanged ancient setup cannot revive after pruning",
    ancientResult.code,
    "22023",
  );
  await reset();
  await route(108, 1, "revoked", 31);
  await receipts(108, 501);
  await cancels(1, 501);
  r = await run();
  same("receipt work capped at 500", r.deliveries, 500);
  same("cancellation work capped at 500", r.cancellations, 500);
  same("route waits for final receipt", r.routes, 0);
  r = await run();
  same("cursor wraps and drains receipt remainder", r.deliveries, 1);
  same("drained old revoked route removed", r.routes, 1);
  same("cancellation remainder pruned", r.cancellations, 1);
  await reset();
  await pg.raw(
    `insert into taskfold_private.email_routes(id,user_id,name,alias_hash,sender_email,requested_at,state,updated_at,alias_domain)
    select gen_random_uuid(),${
      lit(id(1))
    },'Synthetic retired route',md5(n::text)||md5(('route-'||n)::text),'maintenance@example.invalid',now(),'revoked',now()-interval '31 days','mail.example.invalid' from generate_series(1,501)n`,
  );
  same("revoked route work capped at 500", (await run()).routes, 500);
  same("revoked route remainder revisited", (await run()).routes, 1);
  await reset();
  for (let n = 1; n <= 27; n++) await cancels(n, 1);
  r = await run();
  same("twenty accounts maximum", r.accounts, 20);
  same(
    "cursor leaves seven for next run",
    await scalar(
      "select to_jsonb(count(*)) from taskfold_private.email_route_cancellations",
    ),
    7,
  );
  r = await run();
  same("second range drains remaining accounts", r.accounts, 7);
  same("empty job is safe", (await run()).accounts, 0);
  // Hold the exact account lock used by live operations. Cleanup must skip it.
  await reset();
  await cancels(1, 1);
  await cancels(2, 1);
  let holder = await pg.hold(
    `select taskfold_private.automation_account_lock(${lit(id(1))})`,
  );
  r = await run();
  same("busy account skipped", r.skipped, 1);
  same("other account progresses", r.cancellations, 1);
  same(
    "busy account records untouched",
    await scalar(
      `select to_jsonb(count(*)) from taskfold_private.email_route_cancellations where user_id=${
        lit(id(1))
      }`,
    ),
    1,
  );
  await holder.release();
  same("busy account revisited after release", (await run()).cancellations, 1);
  // Inject a lock conflict only after receipt deletion. The account-level
  // subtransaction must restore its receipts and discard speculative counters.
  await reset();
  await route(1090, 1, "revoked", 31);
  await receipts(1090, 1);
  await cancels(2, 1);
  await pg.raw(
    `create function taskfold_private.fixture_email_delete_block()returns trigger language plpgsql set search_path='' as $$begin perform pg_advisory_xact_lock(8675309123::bigint);return old;end$$;
  create trigger fixture_email_delete_block before delete on taskfold_private.email_routes for each row execute function taskfold_private.fixture_email_delete_block()`,
  );
  holder = await pg.hold("select pg_advisory_xact_lock(8675309123::bigint)");
  r = await run();
  same("blocked deletion account skipped", r.skipped, 1);
  same("rolled back receipt not counted", r.deliveries, 0);
  same("other account continues after rollback", r.cancellations, 1);
  same(
    "partial receipt deletion rolled back",
    await scalar(
      `select to_jsonb(count(*)) from taskfold_private.email_deliveries where route_id=${
        lit(id(1090))
      }`,
    ),
    1,
  );
  await holder.release();
  await pg.raw(
    "drop trigger fixture_email_delete_block on taskfold_private.email_routes;drop function taskfold_private.fixture_email_delete_block()",
  );
  r = await run();
  same("retry after blocked deletion removes receipt", r.deliveries, 1);
  same("retry after blocked deletion removes route", r.routes, 1);
  // Concurrent tick returns promptly rather than waiting, duplicating or resetting cursor.
  await cancels(1, 1);
  holder = await pg.hold("select taskfold_private.run_email_maintenance()");
  same("overlapping tick refused", await run(), { state: "busy" });
  await holder.release();
  // A committed cleanup keeps the same account fence until commit. A live
  // intake/management operation must wait, then continue after that transaction.
  await reset();
  await cancels(1, 1);
  holder = await pg.hold("select taskfold_private.run_email_maintenance()");
  const application = "email-maintenance-account-barrier";
  const pending = pg.value(
    `to_jsonb(taskfold_private.automation_account_lock(${lit(id(1))}) is null)`,
    { role: "postgres", app: application },
  );
  summary.accountBarrier = await pg.waitForLock(application, holder.pid);
  same(
    "live operation observes maintenance account lock",
    summary.accountBarrier.blockers.includes(holder.pid),
  );
  await holder.release();
  same(
    "live operation continues after cleanup commit",
    (await pending).code,
    null,
  );
  // An external row lock is skipped and revisited; it does not drop the record.
  await reset();
  await cancels(1, 1);
  holder = await pg.hold(
    "select id from taskfold_private.email_route_cancellations for update",
  );
  same("locked metadata row retained", (await run()).cancellations, 0);
  await holder.release();
  same("unlocked metadata row revisited", (await run()).cancellations, 1);
  await cancels(1, 1);
  await pg.raw("select taskfold_private.configure_email_maintenance(false)");
  same("disabled again leaves eligible records", await run(), {
    state: "disabled",
  });
  same(
    "disable preserves metadata",
    await scalar(
      "select to_jsonb(count(*)) from taskfold_private.email_route_cancellations",
    ),
    1,
  );
  same(
    "no task changes across all runs",
    await scalar(
      "select coalesce(jsonb_agg(to_jsonb(t)order by id),'[]') from public.tasks t",
    ),
    tasks,
  );
  same(
    "monitoring contains aggregates only",
    await scalar(
      "select to_jsonb(array(select jsonb_object_keys(last_counts) order by 1)) from taskfold_private.email_maintenance",
    ),
    ["accounts", "cancellations", "deliveries", "routes", "skipped", "state"],
  );
  // Configuration is atomic if the scheduler extension refuses its update.
  await pg.raw(
    `create or replace function cron.alter_job(job_id bigint,active boolean)returns void language plpgsql as $$begin raise exception 'Synthetic scheduler refusal';end$$`,
  );
  try {
    await pg.raw("select taskfold_private.configure_email_maintenance(true)");
    assert.fail("Allowed failed scheduler update");
  } catch (e) {
    same("scheduler failure surfaced", e.code, "P0001");
  }
  same(
    "scheduler failure rolls back enabled state",
    await scalar(
      "select to_jsonb(not enabled) from taskfold_private.email_maintenance",
    ),
  );
  summary.advisors = await pg.advisors();
  summary.advisors.emailFindings = summary.advisors.result.filter((f) =>
    /email_|taskfold_email_/.test(
      JSON.stringify(f.metadata ?? {}) + " " + f.detail,
    )
  );
  same(
    "official advisors no email warning or error",
    summary.advisors.emailFindings.filter((f) => f.level !== "INFO"),
    [],
  );
  summary.passed = true;
} catch (e) {
  summary.passed = false;
  summary.failure = { message: e.message, code: e.code };
  process.exitCode = 1;
} finally {
  if (pg) summary.containerRemoved = await pg.close();
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(summary, null, 2) + "\n");
  }
  console.log(JSON.stringify(summary));
}
