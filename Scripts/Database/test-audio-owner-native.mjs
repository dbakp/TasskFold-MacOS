import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamProjectSchema } from "./team-project-schema.mjs";
import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
const exec = promisify(execFile),
  repo = fileURLToPath(new URL("../../", import.meta.url)),
  scratch = resolve(process.argv[2] ?? ""),
  report = {
    checks: {},
    deployed: false,
    realProviderAcceptance: false,
    nativeUIClaimed: false,
  };
assert(
  process.argv[2],
  "Supply the independently built Core scratch directory",
);
const check = (n, a, b = true) => {
  assert.deepEqual(a, b, n);
  report.checks[n] = true;
};
let pg, http, folder;
try {
  folder = await mkdtemp(join(tmpdir(), "taskfold-owner-publication-"));
  const binary = join(folder, "proof"), root = join(folder, "storage");
  await mkdir(root, { mode: 0o700 });
  const compile = await exec("swiftc", [
    "-parse-as-library",
    "-swift-version",
    "5",
    "-enable-testing",
    "-I",
    join(scratch, "debug"),
    "-L",
    join(scratch, "debug"),
    "-lTaskfoldCore",
    join(repo, "Scripts/fixtures/AudioCommentNativePublicationProof.swift"),
    "-o",
    binary,
  ], { timeout: 60000 });
  report.compilerWarnings = compile.stderr.split("\n").filter((x) =>
    x.includes("warning:")
  );
  pg = await createPostgresFixture({ advisors: true });
  report.postgresVersion = pg.serverVersion;
  await loadTeamProjectSchema(pg.raw);
  await pg.raw(
    `alter table storage.buckets add column name text,add column file_size_limit bigint,add column allowed_mime_types text[];alter table storage.buckets enable row level security;alter table storage.objects add column metadata jsonb;create unique index audio_fixture_object_identity on storage.objects(bucket_id,name)`,
  );
  for (
    const file of [
      "20261028134424_audio_comment_publication_ledger.sql",
      "20261028145414_audio_comment_gateway_boundary.sql",
      "20261028151901_audio_comment_cleanup_fencing.sql",
      "20261028153218_audio_comment_upload_recovery.sql",
      "20261028185429_audio_comment_keyset_pages.sql",
      "20261028191118_audio_comment_shared_reads.sql",
    ]
  ) {
    await pg.raw(
      await readFile(join(repo, "supabase/migrations", file), "utf8"),
    );
  }
  assert(process.argv[4], "Supply reviewed owner-status migration path");
  await pg.raw(await readFile(process.argv[4], "utf8"));
  const account = randomUUID(),
    session = randomUUID(),
    target = {
      task_id: randomUUID(),
      task_generation: randomUUID(),
      project_id: null,
    };
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at) values(${
      lit(account)
    },'native-publication@example.invalid',now());insert into auth.sessions(id,user_id) values(${
      lit(session)
    },${lit(account)});insert into public.profiles(user_id) values(${
      lit(account)
    });insert into public.tasks(id,user_id,task_generation,title) values(${
      lit(target.task_id)
    },${lit(account)},${
      lit(target.task_generation)
    },'Synthetic native publication');update taskfold_private.audio_comment_config set enabled=true`,
  );
  http = await createAudioHttpFixture(pg, account, session);
  const config = {
    account,
    target,
    source: randomUUID(),
    revision: randomUUID(),
    caption: "  cafe\u0301\nمراجعة 🪴  ",
    endpoint: http.nativeEndpoint,
    token: http.nativeToken,
    lose_reply: true,
    retain_audio: process.argv[4] === "--retain-audio",
  };
  let currentRoot = root;
  const input = join(folder, "input.json");
  const run = async () => {
    await writeFile(input, JSON.stringify(config), { mode: 0o600 });
    const result = await exec(binary, [
      currentRoot,
      join(repo, "TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a"),
      input,
    ], { timeout: 30000, maxBuffer: 64000 });
    return JSON.parse(result.stdout.trim());
  };
  report.baselineAdvisors = await pg.advisors();
  config.prepare_only = true;
  config.status_only = true;
  config.closing = false;
  config.lose_reply = false;
  config.retain_audio = true;
  const prepared = await run();
  check("private preparation makes no HTTP", http.state.authReads, 0);
  check("prepared original remains pending", prepared.pending);
  config.prepare_only = false;
  const checked = await run();
  check("unknown server operation remains unconfirmed", checked.pending);
  check(
    "read-only check does not create publication",
    await pg.scalar(
      "select to_jsonb(count(*)::int) from taskfold_private.audio_comment_publications",
    ),
    0,
  );
  check(
    "read-only check does not create cancellation marker",
    await pg.scalar(
      "select to_jsonb(count(*)::int) from taskfold_private.audio_closed_operations",
    ),
    0,
  );
  check("status sends no media request", http.state.storageRequests, 0);
  check("status keeps original audio", checked.has_audio);
  config.closing = true;
  config.lose_reply = true;
  const lost = await run();
  check("lost cancellation reply remains locally pending", lost.pending);
  check("lost cancellation reply keeps media", lost.has_audio);
  check(
    "server cancellation marker is durable",
    await pg.scalar(
      `select to_jsonb(count(*)::int) from taskfold_private.audio_closed_operations where actor_id=${
        lit(account)
      } and operation_id=${lit(prepared.operation_id)}`,
    ),
    1,
  );
  config.lose_reply = false;
  config.closing = false;
  const closed = await run();
  check("owner status reconciles lost cancellation", closed.closed);
  check(
    "cancellation keeps original operation",
    closed.operation_id,
    prepared.operation_id,
  );
  check("cancellation retains private audio", closed.has_audio);
  const authBeforeCold = http.state.authReads;
  check("closed owner history survives new process", (await run()).closed);
  check(
    "closed cold history makes no HTTP",
    http.state.authReads,
    authBeforeCold,
  );
  const media = await readFile(
    join(repo, "TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a"),
  );
  const delayed = await http.call("publish", {
    intent: prepared.intent,
    audio_base64: media.toString("base64"),
  });
  check(
    "delayed original publish returns closed fence",
    (await delayed.json()).closed.state,
    "closed",
  );
  check(
    "delayed original never creates publication",
    await pg.scalar(
      "select to_jsonb(count(*)::int) from taskfold_private.audio_comment_publications",
    ),
    0,
  );
  check("late original never reaches Storage", http.state.storageRequests, 0);
  config.release_copy = true;
  const compact = await run();
  check("explicit owner-copy release preserves closure", compact.closed);
  check(
    "explicit release removes only local journal media",
    compact.has_audio,
    false,
  );
  config.release_copy = false;
  const project = randomUUID(),
    owner = randomUUID(),
    sharedTask = randomUUID(),
    sharedGeneration = randomUUID();
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at) values(${
      lit(owner)
    },'owner-native-project@example.invalid',now());insert into public.profiles(user_id) values(${
      lit(owner)
    });insert into public.projects(id,user_id,name) values(${lit(project)},${
      lit(owner)
    },'Synthetic lost access');insert into public.tasks(id,user_id,project_id,task_generation,title) values(${
      lit(sharedTask)
    },${lit(owner)},${lit(project)},${
      lit(sharedGeneration)
    },'Synthetic shared original');alter table public.project_collaborators disable trigger taskfold_prepare_invitation;insert into public.project_collaborators(id,project_id,user_id,invited_by,status) values(${
      lit(randomUUID())
    },${lit(project)},${lit(account)},${
      lit(owner)
    },'accepted');alter table public.project_collaborators enable trigger taskfold_prepare_invitation`,
  );
  currentRoot = join(folder, "published-history");
  await mkdir(currentRoot, { mode: 0o700 });
  config.source = randomUUID();
  config.revision = randomUUID();
  config.target = {
    task_id: sharedTask,
    task_generation: sharedGeneration,
    project_id: project,
  };
  config.status_only = false;
  config.lose_reply = true;
  const publishedLost = await run();
  check("lost published ACK keeps pending original", publishedLost.pending);
  check(
    "server baseline did publish",
    await pg.scalar(
      `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
        lit(publishedLost.operation_id)
      }`,
    ),
    "published",
  );
  const storageBeforeHistory = http.state.storageRequests,
    uploadsBeforeHistory = http.state.uploads;
  await pg.raw(
    `delete from public.project_collaborators where project_id=${
      lit(project)
    } and user_id=${
      lit(account)
    };update taskfold_private.audio_comment_config set enabled=false`,
  );
  config.status_only = true;
  config.closing = true;
  config.lose_reply = false;
  config.retain_audio = false;
  const history = await run();
  check(
    "owner cancellation race reconciles published history after revocation",
    history.published,
  );
  check("published history is not a closed proof", history.closed, false);
  check(
    "status retains private original despite compact-send preference",
    history.has_audio,
  );
  check(
    "status after revocation uses no Storage",
    http.state.storageRequests,
    storageBeforeHistory,
  );
  check(
    "status after revocation never uploads",
    http.state.uploads,
    uploadsBeforeHistory,
  );
  check(
    "close request cannot remove published shared comment",
    await pg.scalar(
      `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
        lit(publishedLost.operation_id)
      }`,
    ),
    "published",
  );
  await pg.raw("update taskfold_private.audio_comment_config set enabled=true");
  const denied = await http.call("download", {
    comment_id: publishedLost.comment_id,
  });
  check("owner history grants no current media read", denied.status, 404);
  await denied.arrayBuffer();
  check(
    "denied media read still reaches no Storage",
    http.state.storageRequests,
    storageBeforeHistory,
  );
  currentRoot = join(folder, "deleted-original");
  await mkdir(currentRoot, { mode: 0o700 });
  config.target = target;
  config.source = randomUUID();
  config.revision = randomUUID();
  config.status_only = false;
  config.lose_reply = true;
  http.state.noWrite = true;
  http.state.lostAck = true;
  const orphan = await run();
  check("uncertain orphan starts pending", orphan.pending);
  await pg.raw(`delete from public.tasks where id=${lit(target.task_id)}`);
  config.status_only = true;
  config.closing = false;
  config.lose_reply = false;
  const beforeOrphan = http.state.storageRequests, orphanClosed = await run();
  check(
    "deleted-task owner status settles closed original",
    orphanClosed.closed,
  );
  check("deleted-task status preserves original audio", orphanClosed.has_audio);
  check(
    "deleted-task status starts no media request",
    http.state.storageRequests,
    beforeOrphan,
  );
  check(
    "owner status leaves late upload fence open",
    await pg.scalar(
      `select to_jsonb(count(*)::int) from taskfold_private.audio_upload_attempts where operation_id=${
        lit(orphan.operation_id)
      } and state='open'`,
    ),
    1,
  );
  check("no unexpected SQL or route errors", http.state.errors, []);
  report.finalAdvisors = await pg.advisors();
  check(
    "native owner flow adds no schema advisor findings",
    report.finalAdvisors,
    report.baselineAdvisors,
  );
  report.scope =
    "Separately executed native flow/Backend/full local AAC decode -> production gateway -> real PostgreSQL with controlled Auth/Storage. Metadata checks/cancellation, lost cancellation ACK, delayed publish fencing, historical ACK after revocation/disabled publishing, refused current media access, and deleted-task closure. No hosted provider or native app UI acceptance.";
} finally {
  if (http) await http.close();
  if (pg) report.ownedPostgresContainerRemoved = await pg.close();
  if (folder) await rm(folder, { recursive: true, force: true });
  if (process.argv[3]) {
    await writeFile(process.argv[3], JSON.stringify(report, null, 2) + "\n");
  }
}
console.log(
  Object.keys(report.checks).length +
    " native owner status / gateway / PostgreSQL checks passed",
);
