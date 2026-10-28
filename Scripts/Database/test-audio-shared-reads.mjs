import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamProjectSchema } from "./team-project-schema.mjs";
import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
const report = { checks: {}, deployed: false, providerAcceptance: false },
  check = (n, a, b = true) => {
    assert.deepEqual(a, b, n);
    report.checks[n] = true;
  };
let pg, http, nativeFolder;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadTeamProjectSchema(pg.raw);
  await pg.raw(
    `alter table storage.buckets add column name text,add column file_size_limit bigint,add column allowed_mime_types text[];alter table storage.buckets enable row level security;alter table storage.objects add column metadata jsonb;create unique index audio_fixture_object_identity on storage.objects(bucket_id,name)`,
  );
  for (
    const name of [
      "20261028134424_audio_comment_publication_ledger.sql",
      "20261028145414_audio_comment_gateway_boundary.sql",
      "20261028151901_audio_comment_cleanup_fencing.sql",
      "20261028153218_audio_comment_upload_recovery.sql",
      "20261028185429_audio_comment_keyset_pages.sql",
    ]
  ) {
    await pg.raw(
      await readFile(
        new URL("../../supabase/migrations/" + name, import.meta.url),
        "utf8",
      ),
    );
  }
  const baseline = await pg.advisors();
  await pg.raw(
    await readFile(
      process.argv[3] ??
        new URL(
          "../../supabase/migrations/20261028191118_audio_comment_shared_reads.sql",
          import.meta.url,
        ),
      "utf8",
    ),
  );
  const people = Object.fromEntries(
    ["owner", "viewer", "creator", "outsider"].map(
      (n) => [n, { id: randomUUID(), session: randomUUID() }],
    ),
  );
  for (const [name, u] of Object.entries(people)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${
        lit(name + "@audio.invalid")
      },now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${
        lit(u.id)
      });insert into public.profiles(user_id) values(${lit(u.id)})`,
    );
  }
  const team = randomUUID(),
    project = randomUUID(),
    task = randomUUID(),
    generation = randomUUID(),
    comment = randomUUID(),
    operation = randomUUID(),
    asset = randomUUID(),
    target = {
      task_id: task,
      task_generation: generation,
      project_id: project,
    };
  const bytes = await readFile(
      new URL(
        "../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
        import.meta.url,
      ),
    ),
    audio = {
      version: 1,
      mime_type: "audio/mp4",
      byte_count: bytes.length,
      duration_ms: 1000,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    };
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${lit(project)},${
      lit(people.creator.id)
    },'Shared audio');insert into public.tasks(id,user_id,project_id,task_generation,title) values(${
      lit(task)
    },${lit(people.creator.id)},${lit(project)},${
      lit(generation)
    },'Published before adoption');
 insert into taskfold_private.audio_comment_publications(operation_id,comment_id,asset_id,author_id,task_id,task_generation,project_id,request_hash,sha256,byte_count,caption,audio_descriptor,state,created_at,expires_at,published_at) values(${
      lit(operation)
    },${lit(comment)},${lit(asset)},${lit(people.creator.id)},${lit(task)},${
      lit(generation)
    },${lit(project)},decode(repeat('ab',32),'hex'),${
      lit(audio.sha256)
    },${bytes.length},'Shared recording',${
      lit(JSON.stringify(audio))
    }::jsonb,'published','2026-10-28T12:00:00Z','2026-10-29T12:00:00Z','2026-10-28T12:01:00Z');
 insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(people.owner.id)
    },'Audio team');insert into taskfold_private.team_members values(${
      lit(team)
    },${lit(people.owner.id)},'admin',now()),(${lit(team)},${
      lit(people.viewer.id)
    },'guest',now());
 insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
      lit(project)
    },${
      lit(team)
    },'private');insert into taskfold_private.team_content_tasks values(${
      lit(task)
    },${lit(generation)},${lit(team)},${
      lit(project)
    }) on conflict do nothing;insert into taskfold_private.team_project_grants values(${
      lit(project)
    },${lit(team)},${
      lit(people.viewer.id)
    },'viewer');update taskfold_private.audio_comment_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true`,
  );
  const page = (person = "viewer", t = target) => {
    const u = people[person];
    return pg.value(
      `public.taskfold_audio_comment_page(${lit(u.id)},${lit(u.session)},${
        lit(JSON.stringify({ target: t, after: null }))
      }::jsonb)`,
    );
  };
  const command = (
    action,
    person = "viewer",
    body = { comment_id: comment },
  ) => {
    const u = people[person];
    return pg.value(
      `public.taskfold_audio_comment_command(${lit(action)},${lit(u.id)},${
        lit(u.session)
      },${lit(JSON.stringify(body))}::jsonb)`,
    );
  };
  check(
    "viewer pages another author recording",
    (await page()).value.items[0].author_id,
    people.creator.id,
  );
  check(
    "manager reads existing team audio",
    (await page("owner")).value.items.length,
    1,
  );
  check(
    "creator UUID without membership cannot read",
    (await page("creator")).value.status,
    "unavailable",
  );
  check(
    "outsider cannot read",
    (await page("outsider")).value.status,
    "unavailable",
  );
  check(
    "viewer can read exact published comment",
    (await command("read")).value.comment_id,
    comment,
  );
  check(
    "viewer cannot remove another author recording",
    (await command("remove")).value.status,
    "unavailable",
  );
  const intent = {
    version: 1,
    account: people.viewer.id,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target,
    caption: "Not authorized",
    audio,
  };
  check(
    "team read grant never permits a new publication",
    (await command("reserve", "viewer", intent)).value.status,
    "unavailable",
  );
  await pg.raw(
    `update taskfold_private.audio_comment_publications set author_id=${
      lit(people.viewer.id)
    } where comment_id=${lit(comment)}`,
  );
  check(
    "team author still cannot bypass removal gate",
    (await command("remove")).value.status,
    "unavailable",
  );
  await pg.raw(
    `update public.projects set is_archived=true where id=${lit(project)}`,
  );
  check(
    "archived project recordings remain readable",
    (await page()).value.items.length,
    1,
  );
  check(
    "wrong task generation cannot reuse access",
    (await page("viewer", { ...target, task_generation: randomUUID() })).value
      .status,
    "unavailable",
  );
  http = await createAudioHttpFixture(
    pg,
    people.viewer.id,
    people.viewer.session,
  );
  http.state.objects.set(
    `audio-comments/v1/${task}/${generation}/${asset}.m4a`,
    bytes,
  );
  let response = await http.call("download", { comment_id: comment });
  check("actual gateway returns authorized recording", response.status, 200);
  check(
    "actual shared bytes match original",
    Buffer.from(await response.arrayBuffer()),
    bytes,
  );
  if (process.argv[4]) {
    const exec = promisify(execFile),
      scratch = resolve(process.argv[4]),
      repo = fileURLToPath(new URL("../../", import.meta.url));
    nativeFolder = await mkdtemp(join(tmpdir(), "taskfold-shared-native-"));
    const binary = join(nativeFolder, "proof"),
      input = join(nativeFolder, "input.json");
    const compiled = await exec("swiftc", [
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
    report.nativeCompilerWarnings = compiled.stderr.split("\n").filter((x) =>
      x.includes("warning:")
    );
    await writeFile(
      input,
      JSON.stringify({
        read_only: true,
        account: people.viewer.id,
        target,
        endpoint: http.nativeEndpoint,
        token: http.nativeToken,
      }),
      { mode: 0o600 },
    );
    const result = JSON.parse(
      (await exec(binary, [
        nativeFolder,
        join(repo, "TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a"),
        input,
      ], { timeout: 30000, maxBuffer: 64000 })).stdout.trim(),
    );
    check(
      "actual native viewer lists and decodes shared recording",
      result.read_only_verified,
    );
    check(
      "actual native viewer removal is refused by server",
      result.removal_refused,
    );
    check("read-only native flow uploads no media", http.state.uploads, 0);
  }
  check('refused removal leaves published recording unchanged',await pg.scalar(`select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${lit(operation)}`),'published');
  check('refused team publication created no operation',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.audio_comment_publications where operation_id=${lit(intent.operation_id)}`),0);
  http.state.afterGet = async () => {
    await pg.raw(
      `delete from taskfold_private.team_project_grants where project_id=${
        lit(project)
      } and user_id=${lit(people.viewer.id)}`,
    );
  };
  response = await http.call("download", { comment_id: comment });
  check(
    "grant revoked during Storage read releases no audio",
    response.status,
    404,
  );
  check(
    "revoked download does not expose audio type",
    response.headers.get("Content-Type").includes("audio/"),
    false,
  );
  await response.arrayBuffer();
  http.state.afterGet = null;
  check(
    "revoked grant blocks next page",
    (await page()).value.status,
    "unavailable",
  );
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(people.viewer.id)},'viewer')`,
  );
  check("restored grant can read again", (await page()).value.items.length, 1);
  await pg.raw(
    `update taskfold_private.team_project_config set native_reads_enabled=false`,
  );
  check(
    "team native read switch is enforced",
    (await page()).value.status,
    "unavailable",
  );
  await pg.raw(
    `update taskfold_private.team_project_config set native_reads_enabled=true`,
  );
  await pg.raw(
    `delete from taskfold_private.team_members where team_id=${
      lit(team)
    } and user_id=${lit(people.viewer.id)}`,
  );
  check(
    "removed member cannot read",
    (await command("read")).value.status,
    "unavailable",
  );
  check(
    "removed member cannot page",
    (await page()).value.status,
    "unavailable",
  );
  const legacy = randomUUID(),
    legacyTask = randomUUID(),
    legacyGeneration = randomUUID(),
    legacyComment = randomUUID();
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${lit(legacy)},${
      lit(people.creator.id)
    },'Legacy shared');insert into public.tasks(id,user_id,project_id,task_generation,title) values(${
      lit(legacyTask)
    },${lit(people.creator.id)},${lit(legacy)},${
      lit(legacyGeneration)
    },'Legacy audio');alter table public.project_collaborators disable trigger taskfold_prepare_invitation;insert into public.project_collaborators(id,project_id,user_id,invited_by,status) values(${
      lit(randomUUID())
    },${lit(legacy)},${lit(people.viewer.id)},${
      lit(people.creator.id)
    },'accepted');alter table public.project_collaborators enable trigger taskfold_prepare_invitation;
 insert into taskfold_private.audio_comment_publications(operation_id,comment_id,asset_id,author_id,task_id,task_generation,project_id,request_hash,sha256,byte_count,caption,audio_descriptor,state,created_at,expires_at,published_at) select gen_random_uuid(),${
      lit(legacyComment)
    },gen_random_uuid(),${lit(people.creator.id)},${lit(legacyTask)},${
      lit(legacyGeneration)
    },${
      lit(legacy)
    },request_hash,sha256,byte_count,caption,audio_descriptor,state,created_at,expires_at,published_at from taskfold_private.audio_comment_publications where comment_id=${
      lit(comment)
    }`,
  );
  const legacyTarget = {
    task_id: legacyTask,
    task_generation: legacyGeneration,
    project_id: legacy,
  };
  check(
    "accepted legacy collaborator can page recordings",
    (await page("viewer", legacyTarget)).value.items[0].comment_id,
    legacyComment,
  );
  check(
    "legacy collaborator can read another author recording",
    (await command("read", "viewer", { comment_id: legacyComment })).value
      .author_id,
    people.creator.id,
  );
  check(
    "legacy collaborator cannot remove another author recording",
    (await command("remove", "viewer", { comment_id: legacyComment })).value
      .status,
    "unavailable",
  );
  await pg.raw(
    `delete from public.project_collaborators where project_id=${lit(legacy)}`,
  );
  check(
    "legacy share revocation blocks next page",
    (await page("viewer", legacyTarget)).value.status,
    "unavailable",
  );
  check("adapter has no SQL or routing errors", http.state.errors, []);
  const end = await pg.advisors();
  check(
    "no new advisor findings",
    end.result.filter((x) =>
      !baseline.result.some((y) => x.cache_key === y.cache_key)
    ),
    [],
  );
  report.advisors = end;
} finally {
  if (nativeFolder) await rm(nativeFolder, { recursive: true, force: true });
  if (http) await http.close();
  if (pg) report.ownedPostgresContainerRemoved = await pg.close();
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
}
console.log(
  Object.keys(report.checks).length +
    " shared audio PostgreSQL/gateway checks passed",
);
