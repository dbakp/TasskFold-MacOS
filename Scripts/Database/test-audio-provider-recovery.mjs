// Real local PostgreSQL/Storage and production gateway; controlled synthetic Auth.
// All faults happen after the actual provider/SQL action, never in production code.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createTaskFileProviderDatabase } from "./task-file-provider-schema.mjs";
import { loadTaskFileWorkspaceFixture } from "./task-file-workspace-fixture.mjs";
import {
  audioProjectCustodyMigration,
  audioProjectLedgerDependencies,
  migrationSQL,
} from "./audio-project-custody-schema.mjs";
import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
import { literal as lit } from "./postgres-fixture.mjs";
const [output] = process.argv.slice(2);
assert(output?.startsWith("/tmp/taskfold-") && output.endsWith(".json"));
const account = "ec240000-0000-4000-8000-000000000001",
  creator = "ec240000-0000-4000-8000-000000000099",
  task = "ec240000-0000-4000-8000-000000000002",
  project = "ec240000-0000-4000-8000-000000000003",
  team = "ec240000-0000-4000-8000-000000000004",
  generation = "ec240000-0000-4000-8000-000000000071";
const report = {
  checks: {},
  maintenance: [],
  actualLocalStorage: true,
  genuineAuth: false,
  deployed: false,
  normalUseEnabled: false,
};
const check = (name, a, b = true) => {
  assert.deepEqual(a, b, name);
  report.checks[name] = true;
  console.log("passed:", name);
};
let pg, storage, http;
try {
  execFileSync("python3", ["Scripts/check_test_storage.py", "--path", "/tmp"]);
  ({ pg, storage } = await createTaskFileProviderDatabase());
  for (
    const file of [
      ...audioProjectLedgerDependencies,
      audioProjectCustodyMigration,
    ]
  ) await pg.raw(await migrationSQL(file));
  await loadTaskFileWorkspaceFixture(pg);
  const users = {
    actor: { id: account, session: randomUUID() },
    creator: { id: creator, session: randomUUID() },
  };
  for (const user of Object.values(users)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(user.id)
      },${
        lit(user.id + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${
        lit(user.session)
      },${lit(user.id)});insert into public.profiles(user_id) values(${
        lit(user.id)
      })`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(creator)
    },'Native audio workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(account)},'member'),(${lit(team)},${
      lit(creator)
    },'admin');insert into public.projects(id,user_id,name) values(${
      lit(project)
    },${
      lit(creator)
    },'Design workshop');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
      lit(project)
    },${
      lit(team)
    },'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${
      lit(project)
    },${lit(team)},${
      lit(account)
    },'editor');insert into public.tasks(id,user_id,project_id,task_generation,title,description,subtasks,attachments) values(${
      lit(task)
    },${lit(creator)},${lit(project)},${
      lit(generation)
    },'Team editor proof','Native audio service original','[]','[]');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_task_types_enabled=true;update taskfold_private.audio_comment_config set enabled=true,team_publication_enabled=true`,
  );
  const original = await pg.scalar(
    `select to_jsonb(t) from public.tasks t where id=${lit(task)}`,
  );
  http = await createAudioHttpFixture(pg, account, users.actor.session, {
    storage,
  });
  const media = await readFile(
    new URL(
      "../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
      import.meta.url,
    ),
  );
  const intent = () => ({
    version: 1,
    account,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target: { task_id: task, task_generation: generation, project_id: project },
    caption: "Interrupted service proof",
    audio: {
      version: 1,
      mime_type: "audio/mp4",
      byte_count: media.length,
      duration_ms: 1000,
      sha256: createHash("sha256").update(media).digest("hex"),
    },
  });
  const row = (i) =>
    pg.scalar(
      `select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${
        lit(i.operation_id)
      }`,
    );
  const quota = () =>
    pg.scalar(
      `select coalesce(sum(byte_count),0)::int from taskfold_private.audio_comment_publications where author_id=${
        lit(account)
      } and state<>'purged'`,
    );
  const publish = (i) =>
    http.call("publish", { intent: i, audio_base64: media.toString("base64") });
  const resolve = (i, close = false) =>
    http.call("resolve", { intent: i, close });
  const retire = async (i) => {
    const r = await http.call("remove", { comment_id: i.comment_id });
    assert.equal(r.status, 200, await r.text());
    await pg.raw(
      `update taskfold_private.audio_comment_publications set cleanup_after=clock_timestamp()-interval '1 second' where operation_id=${
        lit(i.operation_id)
      }`,
    );
  };
  const maintain = async () => {
    const r = await http.maintain();
    assert.equal(r.status, 200, await r.clone().text());
    const value = await r.json();
    report.maintenance.push(value);
    return value;
  };

  // The actual object commits, but neither the upload reply nor immediate readback reaches the gateway.
  const a = intent();
  http.state.loseProviderUploadReply = true;
  check("ambiguous upload returns retry", (await publish(a)).status, 503);
  check("stored upload remains pending", (await row(a)).state, "pending");
  check(
    "unresolved writer remains fenced",
    await pg.scalar(
      `select to_jsonb(state) from taskfold_private.audio_upload_attempts where operation_id=${
        lit(a.operation_id)
      }`,
    ),
    "open",
  );
  check("ambiguous upload counts quota", await quota(), media.length);
  const stored = await storage.request(
    "/object/authenticated/taskfold-audio-v1/" + (await row(a)).object_name,
  );
  check(
    "real provider committed exact bytes despite lost reply",
    Buffer.from(await stored.arrayBuffer()),
    media,
  );
  const beforeStatus = http.state.storageRequests;
  const pending = await resolve(a);
  check(
    "metadata status remains unconfirmed",
    (await pending.json()).pending.state,
    "unconfirmed",
  );
  check(
    "status does not contact Storage",
    http.state.storageRequests,
    beforeStatus,
  );
  const recovered = await publish(a);
  check("same intent recovers after interrupted upload", recovered.status, 200);
  const firstReceipt = (await recovered.json()).receipt;
  check(
    "readback recovery settles sole writer",
    await pg.scalar(
      `select to_jsonb(state) from taskfold_private.audio_upload_attempts where operation_id=${
        lit(a.operation_id)
      }`,
    ),
    "settled",
  );
  check("recovery uploads media only once", http.state.uploads, 1);
  const replay = await publish(a);
  check(
    "exact retry retains immutable receipt",
    (await replay.json()).receipt,
    firstReceipt,
  );
  check("exact retry creates no second upload", http.state.uploads, 1);
  await retire(a);

  // Deletion succeeds at Storage, but the worker cannot acknowledge it and must keep quota.
  http.state.loseProviderDeleteReply = true;
  const lostDelete = await maintain();
  check("lost delete acknowledgement remains unresolved", [
    lostDelete.purged,
    lostDelete.unresolved,
  ], [0, 1]);
  check("lost delete retains retired quota", [
    (await row(a)).state,
    await quota(),
  ], ["retired", media.length]);
  const deletesBefore = http.state.providerResults.filter((x) =>
    x.method === "DELETE"
  ).length;
  const liveClaim = await pg.scalar(
    `select to_jsonb(c) from taskfold_private.audio_cleanup_claims c where operation_id=${
      lit(a.operation_id)
    }`,
  );
  const held = await maintain();
  check(
    "active cleanup lease prevents immediate second claim",
    held.claimed,
    0,
  );
  check(
    "active lease prevents duplicate provider deletion",
    http.state.providerResults.filter((x) => x.method === "DELETE").length,
    deletesBefore,
  );
  await pg.raw(
    `update taskfold_private.audio_cleanup_claims set expires_at=clock_timestamp()-interval '1 second' where operation_id=${
      lit(a.operation_id)
    }`,
  );
  // Hold the new claim briefly at the real DELETE boundary so the stale token can be tested.
  const realRequest = storage.request;
  let newToken;
  storage.request = async (...args) => {
    if (args[1]?.method === "DELETE") {
      newToken = await pg.scalar(
        `select to_jsonb(token) from taskfold_private.audio_cleanup_claims where operation_id=${
          lit(a.operation_id)
        }`,
      );
      const old = await pg.value(
        `public.taskfold_audio_comment_maintenance('confirm',${
          lit(
            JSON.stringify({
              operation_id: a.operation_id,
              asset_id: a.asset_id,
              object_name: (await row(a)).object_name,
              token: liveClaim.token,
            }),
          )
        }::jsonb)`,
      );
      check("expired worker cannot release quota", old.value.purged, false);
      check("fresh worker rotates cleanup token", newToken !== liveClaim.token);
    }
    return realRequest(...args);
  };
  const reclaimed = await maintain();
  storage.request = realRequest;
  check(
    "fresh claim idempotently removes already absent real object",
    reclaimed.purged,
    1,
  );
  check("only confirmed cleanup releases quota", [
    (await row(a)).state,
    await quota(),
  ], ["purged", 0]);

  // Finalize committed in PostgreSQL, then its response was lost on the service hop.
  const b = intent();
  http.state.loseFinalizeReply = true;
  check(
    "lost finalization reply returns retry",
    (await publish(b)).status,
    503,
  );
  check(
    "lost finalization still published in SQL",
    (await row(b)).state,
    "published",
  );
  const beforeResolve = [http.state.uploads, http.state.storageRequests];
  const finalStatus = await resolve(b);
  check("metadata resolves committed finalization", finalStatus.status, 200);
  check(
    "resolved receipt matches exact operation",
    (await finalStatus.json()).receipt.operation_id,
    b.operation_id,
  );
  check("metadata recovery never resends or downloads media", [
    http.state.uploads,
    http.state.storageRequests,
  ], beforeResolve);
  await retire(b);
  http.state.loseConfirmReply = true;
  const lostConfirm = await maintain();
  check(
    "lost cleanup confirmation reply is reported unresolved",
    lostConfirm.unresolved,
    1,
  );
  check("committed cleanup retains terminal state", [
    (await row(b)).state,
    await quota(),
  ], ["purged", 0]);
  const beforeRepeat = http.state.storageRequests;
  const repeated = await maintain();
  check("next worker sees committed cleanup", [
    repeated.claimed,
    repeated.purged,
  ], [0, 0]);
  check(
    "terminal cleanup has no second Storage action",
    http.state.storageRequests,
    beforeRepeat,
  );

  // Abandon an unknown upload. Complete stored bytes, not elapsed time, settle its writer fence.
  const c = intent();
  http.state.loseProviderUploadReply = true;
  check(
    "second interrupted upload remains retryable",
    (await publish(c)).status,
    503,
  );
  check(
    "sender can close pending intent",
    (await resolve(c, true)).status,
    200,
  );
  await pg.raw(
    `update taskfold_private.audio_comment_publications set cleanup_after=clock_timestamp()-interval '1 second' where operation_id=${
      lit(c.operation_id)
    }`,
  );
  check(
    "abandoned pending bytes still count quota",
    await quota(),
    media.length,
  );
  const reconciled = await maintain();
  check(
    "worker hashes stored bytes before settling abandoned upload",
    reconciled.recovered,
    1,
  );
  check("reconciled retired upload is purged", reconciled.purged, 1);
  check("all quota released only after confirmed cleanup", await quota(), 0);
  check(
    "one provider upload for each immutable operation",
    http.state.uploads,
    3,
  );
  check(
    "all operation identities retained",
    await pg.scalar(
      "select count(*)::int from taskfold_private.audio_comment_publications",
    ),
    3,
  );
  check(
    "all operations end purged",
    await pg.scalar(
      "select count(*)::int from taskfold_private.audio_comment_publications where state='purged'",
    ),
    3,
  );
  check(
    "no unresolved writer survives recovery",
    await pg.scalar(
      "select count(*)::int from taskfold_private.audio_upload_attempts where state='open'",
    ),
    0,
  );
  check(
    "task content remains exact",
    await pg.scalar(
      `select to_jsonb(t) from public.tasks t where id=${lit(task)}`,
    ),
    original,
  );
  check(
    "all deliberate fault switches consumed",
    [
      "loseProviderUploadReply",
      "failNextProviderRead",
      "loseProviderDeleteReply",
      "loseFinalizeReply",
      "loseConfirmReply",
    ].every((k) => http.state[k] === false),
  );
  check("SQL adapter reports no unexpected errors", http.state.errors, []);
} catch (error) {
  report.error = { message: error.message };
  throw error;
} finally {
  if (http) report.provider = http.state.providerResults;
  report.checkCount = Object.keys(report.checks).length;
  report.cleanupErrors = [];
  for (
    const [resource, key] of [
      [http, "httpClosed"],
      [storage, "storageRemoved"],
      [pg, "databaseRemoved"],
    ]
  ) {
    try {
      if (resource) report[key] = await resource.close();
    } catch (e) {
      report.cleanupErrors.push(e.message);
    }
  }
  await writeFile(output, JSON.stringify(report, null, 2) + "\n");
}
assert.deepEqual(report.cleanupErrors, []);
console.log(
  JSON.stringify({ checks: report.checkCount, cleanup: report.cleanupErrors }),
);
