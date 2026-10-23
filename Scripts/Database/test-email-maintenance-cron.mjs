import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createCronPostgresFixture } from "./postgres-cron-fixture.mjs";
import { loadEmailIntakeSchema } from "./email-intake-schema.mjs";
const summary = {
  date: new Date().toISOString(),
  checks: {},
  hostedAcceptance: false,
};
let pg;
const same = (name, a, b = true) => {
  summary.checks[name] = false;
  assert.deepEqual(a, b, name);
  summary.checks[name] = true;
};
const delay = (n) => new Promise((r) => setTimeout(r, n));
try {
  pg = await createCronPostgresFixture();
  summary.cronSource = pg.cronSource;
  summary.librarySha256 = pg.librarySha256;
  summary.postgresVersion = pg.serverVersion;
  await loadEmailIntakeSchema(pg.raw);
  await pg.raw("create extension pg_cron");
  same(
    "actual extension version",
    await pg.scalar(
      "select to_jsonb(extversion) from pg_extension where extname='pg_cron'",
    ),
    "1.6",
  );
  await pg.raw(
    await readFile(
      new URL(
        "../../supabase/migrations/20261023182542_email_inactive_maintenance.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  same(
    "actual installed cron job inactive",
    await pg.scalar(
      "select to_jsonb(not active) from cron.job where jobname='taskfold-email-maintenance'",
    ),
  );
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at)values('f0e5cafe-0000-4000-8000-000000000001','cron@example.invalid',now());
 insert into taskfold_private.email_route_cancellations(id,user_id,created_at)values('f0e5cafe-0000-4000-8000-000000000002','f0e5cafe-0000-4000-8000-000000000001',now()-interval '31 days'),('f0e5cafe-0000-4000-8000-000000000003','f0e5cafe-0000-4000-8000-000000000001',now());
 select cron.alter_job((select jobid from cron.job where jobname='taskfold-email-maintenance'),schedule:='1 second');
 select taskfold_private.configure_email_maintenance(true);`,
  );
  let completed = false;
  for (let n = 0; n < 150; n++) {
    if (
      await pg.scalar(
        "select to_jsonb(exists(select 1 from cron.job_run_details where jobid=(select jobid from cron.job where jobname='taskfold-email-maintenance') and status='succeeded'))",
      )
    ) {
      completed = true;
      break;
    }
    await delay(100);
  }
  same("actual timer invokes cleanup successfully", completed);
  same(
    "inactive old record removed by timer",
    await pg.scalar(
      "select to_jsonb(not exists(select 1 from taskfold_private.email_route_cancellations where id='f0e5cafe-0000-4000-8000-000000000002'))",
    ),
  );
  same(
    "recent record retained by timer",
    await pg.scalar(
      "select to_jsonb(exists(select 1 from taskfold_private.email_route_cancellations where id='f0e5cafe-0000-4000-8000-000000000003'))",
    ),
  );
  same(
    "timer writes private aggregate health",
    await pg.scalar(
      "select to_jsonb(last_run_at is not null and last_counts->>'state'='finished') from taskfold_private.email_maintenance",
    ),
  );
  await pg.raw("select taskfold_private.configure_email_maintenance(false)");
  const stamp = await pg.scalar(
    "select to_jsonb(last_run_at) from taskfold_private.email_maintenance",
  );
  await delay(2200);
  same(
    "disabled timer performs no further cleanup",
    await pg.scalar(
      "select to_jsonb(last_run_at) from taskfold_private.email_maintenance",
    ),
    stamp,
  );
  same(
    "actual job remains inactive",
    await pg.scalar(
      "select to_jsonb(not active) from cron.job where jobname='taskfold-email-maintenance'",
    ),
  );
  // Shorten only the fixture deadline and replace its action with pg_sleep to
  // prove SET-before-SELECT actually cancels a scheduler query in this mode.
  await pg.raw(
    `select cron.alter_job((select jobid from cron.job where jobname='taskfold-email-maintenance'),command:='set statement_timeout=''50ms''; select pg_sleep(1);',active:=true)`,
  );
  let timeoutObserved = false;
  for (let n = 0; n < 100; n++) {
    if (
      await pg.scalar(
        "select to_jsonb(exists(select 1 from cron.job_run_details where status='failed' and return_message like '%statement timeout%'))",
      )
    ) {
      timeoutObserved = true;
      break;
    }
    await delay(100);
  }
  same("actual timer enforces SET before query deadline", timeoutObserved);
  await pg.raw(
    "select cron.alter_job((select jobid from cron.job where jobname='taskfold-email-maintenance'),active:=false)",
  );
  summary.connectionFixtureRemoved = await pg.close();
  pg = null;
  // A different actual engine mode must fail safely rather than pretend its SET
  // command supplies a hard timeout. No global scheduler setting is changed.
  pg = await createCronPostgresFixture({ backgroundWorkers: true });
  await loadEmailIntakeSchema(pg.raw);
  await pg.raw("create extension pg_cron");
  await pg.raw(
    await readFile(
      new URL(
        "../../supabase/migrations/20261023182542_email_inactive_maintenance.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  try {
    await pg.raw("select taskfold_private.configure_email_maintenance(true)");
    assert.fail("Unsupported scheduler mode enabled");
  } catch (e) {
    same("actual background worker mode refused", e.code, "P0001");
  }
  same(
    "unsupported mode keeps state and job inactive",
    await pg.scalar(
      "select to_jsonb(not s.enabled and not j.active)from taskfold_private.email_maintenance s cross join cron.job j where j.jobname='taskfold-email-maintenance'",
    ),
  );
  // Simulate an operator-enabled state carried across an engine-mode restart.
  await pg.raw(`update taskfold_private.email_maintenance set enabled=true;
  insert into auth.users(id,email)values('f0e5cafe-0000-4000-8000-000000000001','mode@example.invalid');
  insert into taskfold_private.email_route_cancellations(id,user_id,created_at)values('f0e5cafe-0000-4000-8000-000000000002','f0e5cafe-0000-4000-8000-000000000001',now()-interval '31 days')`);
  same(
    "mode change after enablement blocks cleanup",
    await pg.scalar("select taskfold_private.run_email_maintenance()"),
    { state: "unsupported_scheduler" },
  );
  same(
    "unsupported mode retains old metadata",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.email_route_cancellations",
    ),
    1,
  );
  same(
    "unsupported mode publishes aggregate health",
    await pg.scalar(
      "select to_jsonb(last_counts->>'state') from taskfold_private.email_maintenance",
    ),
    "unsupported_scheduler",
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
