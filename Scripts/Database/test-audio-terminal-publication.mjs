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
  folder = await mkdtemp(join(tmpdir(), "taskfold-terminal-publication-"));
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
  const media = await readFile(
    join(repo, "TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a"),
  );
  for (const variant of ["absent", "corrupt"]) {
    currentRoot = join(folder, variant);
    await mkdir(currentRoot, { mode: 0o700 });
    config.source = randomUUID();
    config.revision = randomUUID();
    config.lose_reply = true;
    config.retain_audio = true;
    config.release_copy = false;
    http.state.noWrite = variant === "absent";
    http.state.corrupt = variant === "corrupt";
    http.state.lostAck = variant === "absent";
    const first = await run();
    check(variant + " uncertain original keeps media", first.has_audio);
    check(variant + " no false confirmation", first.published, false);
    check(variant + " no false closure", first.closed, false);
    check(
      variant + " real SQL remains pending",
      await pg.scalar(
        `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
          lit(first.operation_id)
        }`,
      ),
      "pending",
    );
    await pg.raw(
      `update taskfold_private.audio_comment_publications set expires_at=clock_timestamp()-interval '1 second' where operation_id=${
        lit(first.operation_id)
      }`,
    );
    const lostClosure = await run();
    check(
      variant + " lost closed response remains locally uncertain",
      lostClosure.closed,
      false,
    );
    check(
      variant + " lost closed response preserves recording",
      lostClosure.has_audio,
    );
    check(
      variant + " server closure survives lost response",
      await pg.scalar(
        `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
          lit(first.operation_id)
        }`,
      ),
      "retired",
    );
    config.lose_reply = false;
    const uploads = http.state.uploads, closed = await run();
    check(variant + " native settles exact closed proof", closed.closed);
    check(variant + " does not claim never-published", closed.published, false);
    check(
      variant + " retains original operation",
      closed.operation_id,
      first.operation_id,
    );
    check(variant + " retains caption", closed.caption, config.caption);
    check(
      variant + " retains original comment identity",
      closed.comment_id,
      first.comment_id,
    );
    check(
      variant + " retains original asset identity",
      closed.asset_id,
      first.asset_id,
    );
    check(variant + " closure retains media", closed.has_audio);
    check(
      variant + " terminal retry does not upload",
      http.state.uploads,
      uploads,
    );
    check(
      variant + " server permanently retired operation",
      await pg.scalar(
        `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
          lit(first.operation_id)
        }`,
      ),
      "retired",
    );
    const reads = http.state.authReads, third = await run();
    check(variant + " cold closed state survives", third.closed);
    check(
      variant + " cold closed retry has no HTTP",
      http.state.authReads,
      reads,
    );
    config.release_copy = true;
    const compact = await run();
    check(variant + " explicit release retains closed proof", compact.closed);
    check(
      variant + " explicit release only removes local media",
      compact.has_audio,
      false,
    );
    check(
      variant + " compact proof remains terminal after relaunch",
      (await run()).closed,
    );
    check(
      variant + " local release sends no HTTP",
      http.state.authReads,
      reads,
    );
    const forged = await http.call("publish", {
      intent: { ...first.intent, caption: "Changed literal caption" },
      audio_base64: media.toString("base64"),
    });
    check(
      variant + " changed intent cannot adopt terminal proof",
      forged.status,
      409,
    );
    check(
      variant + " conflict has no closed proof",
      Object.hasOwn(await forged.json(), "closed"),
      false,
    );
    check(
      variant + " changed intent never uploads",
      http.state.uploads,
      uploads,
    );
    const final = await pg.scalar(
      `select jsonb_build_object('state',p.state,'open',count(u.ticket_id) filter(where u.state='open')) from taskfold_private.audio_comment_publications p left join taskfold_private.audio_upload_attempts u using(operation_id) where p.operation_id=${
        lit(first.operation_id)
      } group by p.state`,
    );
    check(
      variant + " upload fence remains independent of client closure",
      final,
      { state: "retired", open: variant === "absent" ? 1 : 0 },
    );
  }
  check("no adapter SQL/routing errors", http.state.errors, []);
  report.finalAdvisors = await pg.advisors();
  check(
    "no added schema advisor findings",
    report.finalAdvisors,
    report.baselineAdvisors,
  );
  report.scope =
    "Native Core/Backend/full AAC decode in separate processes -> production Deno gateway -> real PostgreSQL with controlled Auth/Storage. Absent/corrupt stored bytes stay uncertain until the existing exact reservation expires, then native v3 closure survives cold retry and explicit local compaction without HTTP. No hosted provider or native app UI acceptance; schema unchanged.";
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
    " native / gateway / PostgreSQL terminal recovery checks passed",
);
