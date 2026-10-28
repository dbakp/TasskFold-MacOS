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
  folder = await mkdtemp(join(tmpdir(), "taskfold-native-publication-"));
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
  pg = await createPostgresFixture();
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
  const input = join(folder, "input.json");
  const run = async () => {
    await writeFile(input, JSON.stringify(config), { mode: 0o600 });
    const result = await exec(binary, [
      root,
      join(repo, "TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a"),
      input,
    ], { timeout: 30000, maxBuffer: 64000 });
    return JSON.parse(result.stdout.trim());
  };
  const first = await run();
  check(
    "lost native response keeps journal unconfirmed",
    first.published,
    false,
  );
  check("lost native response retains exact local audio", first.has_audio);
  check(
    "server did publish before native response was lost",
    await pg.scalar(
      `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
        lit(first.operation_id)
      }`,
    ),
    "published",
  );
  check("only one actual Storage upload", http.state.uploads, 1);
  config.lose_reply = false;
  const second = await run();
  check(
    "new native process reconciles actual gateway receipt",
    second.published,
  );
  check("retry uses same operation", second.operation_id, first.operation_id);
  check("retry uses same comment", second.comment_id, first.comment_id);
  check("retry preserves exact caption", second.caption, config.caption);
  check("retry does not upload again", http.state.uploads, 1);
  check(
    "native confirmation obeys explicit local retention",
    second.has_audio,
    config.retain_audio,
  );
  const before = http.state.authReads, third = await run();
  check(
    "confirmed native restart keeps original operation",
    third.operation_id,
    first.operation_id,
  );
  check("confirmed native restart sends no HTTP", http.state.authReads, before);
  if (config.retain_audio) {
    config.source = first.asset_id;
    config.revision = first.operation_id;
    const recoveredCopy = await run();
    check(
      "private recovery copy reuses confirmed native operation",
      recoveredCopy.operation_id,
      first.operation_id,
    );
    check("private recovery copy sends no HTTP", http.state.authReads, before);
    config.release_copy = true;
    const released = await run();
    check("explicit native release keeps confirmation", released.published);
    check(
      "explicit native release removes only journal audio",
      released.has_audio,
      false,
    );
    config.release_copy = false;
    const returned = await run();
    check(
      "released native restart preserves original operation",
      returned.operation_id,
      first.operation_id,
    );
    check("release and restart send no HTTP", http.state.authReads, before);
  }
  const media = await readFile(
    join(repo, "TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a"),
  );
  check(
    "native/server media digest matches original",
    third.sha256,
    createHash("sha256").update(media).digest("hex"),
  );
  config.read_remote = true;
  const remote = await run();
  check("native lists downloads retries lost removal reply and rechecks actual gateway", remote.remote_checked);
  check("remote removal leaves local confirmation proof", remote.published);
  check("remote read never uploads another object", http.state.uploads, 1);
  check("remote removal retires actual server operation", await pg.scalar(`select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${lit(first.operation_id)}`), "retired");
  check("adapter has no SQL or routing errors", http.state.errors, []);
  report.scope =
    "Actual separately executed native Core flow/Backend/native AAC decode -> controlled HTTPS-to-loopback URLProtocol mapping -> production Deno gateway -> real PostgreSQL -> controlled Auth/Storage byte API. Lost native ACK, restart retry, retained/compact receipt restart, authenticated list/full native download/remove, empty list and refused download after removal. No hosted provider or iPhone/iPad/Mac app UI acceptance.";
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
    " native / gateway / PostgreSQL publication checks passed",
);
