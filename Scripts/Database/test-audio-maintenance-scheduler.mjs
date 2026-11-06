import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, createHmac, randomUUID } from "node:crypto";
import { literal as lit } from "./postgres-fixture.mjs";
import { createCronPostgresFixture } from "./postgres-cron-fixture.mjs";
import { loadTeamProjectSchema } from "./team-project-schema.mjs";
import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
const report = {
  checks: {},
  hostedCronClaimed: false,
  realDataChanged: false,
  deployed: false,
  controlledPgNet: true,
  controlledVault: true,
};
const check = (n, a, b = true) => {
  assert.deepEqual(a, b, n);
  report.checks[n] = true;
};
let pg, http;
try {
  pg = await createCronPostgresFixture({
    backgroundWorkers: true,
    advisors: true,
  });
  report.postgresVersion = pg.serverVersion;
  report.cronSource = pg.cronSource;
  report.librarySHA256 = pg.librarySha256;
  await loadTeamProjectSchema(pg.raw);
  await pg.raw(`create extension pg_cron;
 alter table storage.buckets add column name text,add column file_size_limit bigint,add column allowed_mime_types text[];alter table storage.buckets enable row level security;alter table storage.objects add column metadata jsonb;create unique index audio_fixture_object_identity on storage.objects(bucket_id,name);
 create schema vault;create table vault.decrypted_secrets(name text,decrypted_secret text);
 create schema net;create table net._http_response(id bigint,status_code integer,timed_out boolean,created timestamptz);
 create table net.fixture_requests(id bigint generated always as identity,url text,headers jsonb,body jsonb,timeout integer);
 create function net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds integer) returns bigint language plpgsql as $$declare request_id bigint;begin
 if current_setting('fixture.fail',true)='1' then raise exception 'PRIVATE FIXTURE SECRET %',headers;end if;
 insert into net.fixture_requests(url,headers,body,timeout) values(url,headers,body,timeout_milliseconds) returning id into request_id;return request_id;end$$;`);
  report.baselineAdvisors = await pg.advisors();
  for (
    const file of [
      "20261028134424_audio_comment_publication_ledger.sql",
      "20261028145414_audio_comment_gateway_boundary.sql",
      "20261028151901_audio_comment_cleanup_fencing.sql",
      "20261028153218_audio_comment_upload_recovery.sql",
      "20261028153219_audio_comment_maintenance_scheduler.sql",
    ]
  ) {
    const source = await readFile(
      new URL("../../supabase/migrations/" + file, import.meta.url),
      "utf8",
    );
    report[file] = createHash("sha256").update(source).digest("hex");
    await pg.raw(source);
  }
  const job = await pg.scalar(
    `select jsonb_build_object('schedule',schedule,'command',command,'active',active,'username',username) from cron.job where jobname='taskfold-audio-maintenance'`,
  );
  check("real pg_cron job installed inactive", job.active, false);
  check("minute cadence", job.schedule, "* * * * *");
  check("job owned by postgres", job.username, "postgres");
  check(
    "cron text has no credential or URL",
    job.command,
    "select taskfold_private.invoke_audio_maintenance_worker();",
  );
  check(
    "disabled invocation queues nothing",
    await pg.scalar(
      `select coalesce(to_jsonb(taskfold_private.invoke_audio_maintenance_worker()),'null'::jsonb)`,
    ),
    null,
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    check(
      role + " cannot configure scheduler",
      await pg.scalar(
        `select to_jsonb(has_function_privilege('${role}','taskfold_private.configure_audio_maintenance_scheduler(text,boolean)','execute'))`,
      ),
      false,
    );
    check(
      role + " cannot invoke scheduler",
      await pg.scalar(
        `select to_jsonb(has_function_privilege('${role}','taskfold_private.invoke_audio_maintenance_worker()','execute'))`,
      ),
      false,
    );
  }
  await assert.rejects(
    pg.raw(
      `select taskfold_private.configure_audio_maintenance_scheduler('${
        "a".repeat(20)
      }',true)`,
    ),
  );
  report.checks["missing Vault credential prevents enable"] = true;
  await pg.raw(
    `insert into vault.decrypted_secrets values('taskfold_audio_maintenance_key','${
      "b".repeat(64)
    }');select taskfold_private.configure_audio_maintenance_scheduler('${
      "a".repeat(20)
    }',true);select cron.alter_job((select jobid from cron.job where jobname='taskfold-audio-maintenance'),schedule:='1 second')`,
  );
  let queued = false;
  for (let n = 0; n < 80; n++) {
    if (
      await pg.scalar(`select to_jsonb(count(*)>0) from net.fixture_requests`)
    ) {
      queued = true;
      break;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  check("actual cron background worker enqueues signed tick", queued);
  await pg.raw(
    `select cron.alter_job((select jobid from cron.job where jobname='taskfold-audio-maintenance'),active:=false)`,
  );
  const request = await pg.scalar(
    `select jsonb_build_object('url',url,'headers',headers,'body',body,'timeout',timeout) from net.fixture_requests order by id limit 1`,
  );
  check(
    "fixed hosted function route",
    request.url,
    `https://${
      "a".repeat(20)
    }.supabase.co/functions/v1/audio-comment-maintenance`,
  );
  check("bounded HTTP timeout", request.timeout, 25000);
  check("empty task-free payload", request.body, {});
  const proof = request.headers["X-Taskfold-Audio-Schedule"],
    parts = proof.split(".");
  check(
    "no reusable secret in queued headers",
    JSON.stringify(request.headers).includes("b".repeat(64)),
    false,
  );
  check(
    "queued proof uses expected HMAC",
    parts[2],
    createHmac("sha256", "b".repeat(64)).update(
      `taskfold.audio.maintenance.v1.${parts[0]}.${parts[1]}.${"a".repeat(20)}`,
    ).digest("hex"),
  );
  http = await createAudioHttpFixture(
    pg,
    "00000000-0000-0000-0000-000000000001",
    "00000000-0000-0000-0000-000000000002",
  );
  // Synthetic retired tombstone models a removed task/account. The late file
  // has committed, but its upload acknowledgement was lost.
  const op = randomUUID(),
    asset = randomUUID(),
    task = randomUUID(),
    generation = randomUUID();
  const audio = await readFile(
    new URL(
      "../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
      import.meta.url,
    ),
  );
  const path = `audio-comments/v1/${task}/${generation}/${asset}.m4a`,
    hash = createHash("sha256").update(audio).digest("hex");
  await pg.raw(
    `insert into taskfold_private.audio_comment_publications(operation_id,comment_id,asset_id,task_id,task_generation,request_hash,sha256,byte_count,state,cleanup_after) values(${
      lit(op)
    },${lit(randomUUID())},${lit(asset)},${lit(task)},${
      lit(generation)
    },decode('${"a".repeat(64)}','hex'),${
      lit(hash)
    },${audio.length},'retired',clock_timestamp()-interval '1 minute');insert into taskfold_private.audio_upload_attempts(operation_id) values(${
      lit(op)
    });insert into storage.objects(id,bucket_id,name,metadata) values(${
      lit(randomUUID())
    },'taskfold-audio-v1',${lit(path)},${
      lit(JSON.stringify({ size: audio.length, mimetype: "audio/mp4" }))
    }::jsonb)`,
  );
  http.state.objects.set(path, audio);
  let r = await http.maintain(proof);
  check(
    "real SQL-generated proof reaches production HTTP worker",
    r.status,
    200,
  );
  const body = await r.json();
  check(
    "scheduled production worker claims recovered retired file",
    body.claimed,
    1,
  );
  check(
    "scheduled worker verifies and recovers lost upload",
    body.recovered,
    1,
  );
  check("scheduled worker confirms Storage removal", body.purged, 1);
  check(
    "scheduled worker removed actual fixture bytes",
    http.state.objects.has(path),
    false,
  );
  check(
    "scheduled worker releases retired quota",
    await pg.scalar(
      `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
        lit(op)
      }`,
    ),
    "purged",
  );
  r = await http.maintain(proof);
  check("real SQL rejects scheduled replay", r.status, 401);
  await r.body.cancel();
  check(
    "cooldown skips another enqueue",
    await pg.scalar(
      `select coalesce(to_jsonb(taskfold_private.invoke_audio_maintenance_worker()),'null'::jsonb)`,
    ),
    null,
  );
  await pg.raw(
    `update taskfold_private.audio_maintenance_scheduler set last_queued_at=clock_timestamp()-interval '1 minute';set fixture.fail='1';select taskfold_private.invoke_audio_maintenance_worker()`,
  );
  check(
    "enqueue failure is sanitized state",
    await pg.scalar(
      `select to_jsonb(last_state) from taskfold_private.audio_maintenance_scheduler where singleton`,
    ),
    "enqueue_failed",
  );
  await pg.raw(
    `select taskfold_private.configure_audio_maintenance_scheduler(null,false)`,
  );
  check(
    "disable deactivates actual job",
    await pg.scalar(
      `select to_jsonb(active) from cron.job where jobname='taskfold-audio-maintenance'`,
    ),
    false,
  );
  check(
    "disable invalidates stored nonce",
    await pg.scalar(
      `select to_jsonb(scheduled_nonce is null) from taskfold_private.audio_maintenance_scheduler where singleton`,
    ),
  );
  check(
    "disabled scheduler cannot enqueue",
    await pg.scalar(
      `select coalesce(to_jsonb(taskfold_private.invoke_audio_maintenance_worker()),'null'::jsonb)`,
    ),
    null,
  );
  check(
    "only one request was committed",
    await pg.scalar(`select to_jsonb(count(*)) from net.fixture_requests`),
    1,
  );
  check("HTTP adapter saw no SQL or routing failures", http.state.errors, []);
  report.finalAdvisors = await pg.advisors();
  const baseline = new Set(
    report.baselineAdvisors.result.map((x) => x.cache_key),
  );
  check(
    "no introduced advisor findings",
    report.finalAdvisors.result.filter((x) => !baseline.has(x.cache_key)),
    [],
  );
} finally {
  if (http) await http.close();
  if (pg) report.ownedPostgresContainerRemoved = await pg.close();
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
}
console.log(
  Object.keys(report.checks).length +
    " real pg_cron / signed HTTP maintenance checks passed",
);
