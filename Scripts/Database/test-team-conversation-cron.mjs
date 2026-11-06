import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createCronPostgresFixture } from "./postgres-cron-fixture.mjs";
import { loadTeamTaskLifecycle } from "./team-task-schema.mjs";
import {
  loadTeamConversationSchema,
  teamConversationMigration,
} from "./team-conversation-schema.mjs";
const report = {
  checks: {},
  deployed: false,
  realDataChanged: false,
  hostedCronClaimed: false,
};
const check = (n, a, b = true) => {
  assert.deepEqual(a, b, n);
  report.checks[n] = true;
};
let pg, holder;
try {
  pg = await createCronPostgresFixture({ backgroundWorkers: true });
  await loadTeamTaskLifecycle(pg.raw);
  await pg.raw("create extension pg_cron");
  await loadTeamConversationSchema(pg.raw, { base: false });
  report.cronSource = pg.cronSource;
  report.librarySHA256 = pg.librarySha256;
  report.postgresVersion = pg.serverVersion;
  report.migrationSHA256 = createHash("sha256").update(
    await readFile(
      new URL(
        "../../supabase/migrations/" + teamConversationMigration,
        import.meta.url,
      ),
    ),
  ).digest("hex");
  const job = await pg.scalar(
    "select jsonb_build_object('schedule',schedule,'command',command,'active',active,'username',username) from cron.job where jobname='taskfold-team-conversation-recovery'",
  );
  check("actual hourly cleanup job registered", job.schedule, "27 * * * *");
  check("job active", job.active);
  check(
    "job uses guarded cleanup",
    job.command,
    "select taskfold_private.expire_team_conversations(1000)",
  );
  check("job owned by postgres", job.username, "postgres");
  const user = randomUUID(),
    team = randomUUID(),
    expired = randomUUID(),
    locked = randomUUID(),
    current = randomUUID();
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at) values('${user}','cron@example.invalid',now());insert into taskfold_private.teams(id,owner_id,name) values('${team}','${user}','Cron fixture');insert into taskfold_private.team_members(team_id,user_id,role) values('${team}','${user}','admin');`,
  );
  for (const [q, old] of [[expired, true], [locked, true], [current, false]]) {
    await pg.raw(
      `insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation,conversation_state) values('${team}','${q}','${user}','synthetic-digest','${randomUUID()}','${randomUUID()}','delete','ready');insert into taskfold_private.team_conversation_keys(team_id,request_id,secret,expires_at)values('${team}','${q}',extensions.gen_random_bytes(32),clock_timestamp()+interval '${
        old ? "-31 days" : "1 day"
      }');insert into taskfold_private.team_conversation_archive(team_id,request_id,comment_id,payload)values('${team}','${q}','${randomUUID()}',extensions.pgp_sym_encrypt('Synthetic recovery',encode((select secret from taskfold_private.team_conversation_keys where request_id='${q}'),'base64'),'cipher-algo=aes256'));`,
    );
  }
  holder = await pg.hold(
    `select request_id from taskfold_private.team_task_edits where request_id='${locked}' for update`,
  );
  await pg.raw(
    "select cron.alter_job((select jobid from cron.job where jobname='taskfold-team-conversation-recovery'),schedule:='1 second')",
  );
  let done = false;
  for (let i = 0; i < 80; i++) {
    if (
      await pg.scalar(
        `select to_jsonb(not exists(select 1 from taskfold_private.team_conversation_keys where request_id='${expired}'))`,
      )
    ) {
      done = true;
      break;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  check("real worker expires encrypted recovery", done);
  check(
    "real worker leaves locked receipt",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_keys where request_id='${locked}'`,
    ),
    1,
  );
  check(
    "real worker preserves unexpired archive",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_archive where request_id='${current}'`,
    ),
    1,
  );
  await holder.release("commit");
  holder = null;
  done = false;
  for (let i = 0; i < 80; i++) {
    if (
      await pg.scalar(
        `select to_jsonb(not exists(select 1 from taskfold_private.team_conversation_keys where request_id='${locked}'))`,
      )
    ) {
      done = true;
      break;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  check("real worker retries unlocked archive", done);
  check(
    "expired ciphertext removed",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_archive where request_id in('${expired}','${locked}')`,
    ),
    0,
  );
  check(
    "expired receipts remain fenced",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_task_edits where request_id in('${expired}','${locked}') and conversation_state='expired'`,
    ),
    2,
  );
  check(
    "actual worker reports success",
    await pg.scalar(
      "select to_jsonb(exists(select 1 from cron.job_run_details where jobid=(select jobid from cron.job where jobname='taskfold-team-conversation-recovery') and status='succeeded'))",
    ),
  );
  report.containerRemoved = await pg.close();
  pg = null;
  report.checkCount = Object.keys(report.checks).length;
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
  console.log(
    JSON.stringify({
      checks: report.checkCount,
      containerRemoved: report.containerRemoved,
    }),
  );
} finally {
  if (holder) await holder.release("rollback");
  if (pg) await pg.close();
}
