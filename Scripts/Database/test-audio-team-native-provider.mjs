// Actual local SQL/RLS, production gateway and pinned Storage API. Sign-in and
// native HTTPS/PostgREST routing remain controlled synthetic adapters.
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { createWriteStream } from "node:fs";
import { readdir, readFile, unlink, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createTaskFileProviderDatabase } from "./task-file-provider-schema.mjs";
import {
  loadTaskFileWorkspaceFixture,
  workspaceTables,
} from "./task-file-workspace-fixture.mjs";
import {
  audioProjectCustodyMigration,
  audioProjectLedgerDependencies,
  migrationSQL,
} from "./audio-project-custody-schema.mjs";
import { createAudioTeamNativeHttp } from "./audio-team-native-http.mjs";
import { literal as lit } from "./postgres-fixture.mjs";
import { homedir } from "node:os";
const exec = promisify(execFile);
const [platform, output] = process.argv.slice(2);
assert(
  ["service", "ios", "ipad", "ios-expired", "ios-recorded"].includes(platform) &&
    output?.startsWith("/tmp/taskfold-") && output.endsWith(".json"),
);
const account = "ec240000-0000-4000-8000-000000000001",
  creator = "ec240000-0000-4000-8000-000000000099",
  task = "ec240000-0000-4000-8000-000000000002",
  project = "ec240000-0000-4000-8000-000000000003",
  team = "ec240000-0000-4000-8000-000000000004",
  generation = "ec240000-0000-4000-8000-000000000071";
const expiredRecovery = platform === "ios-expired";
const recordedRecovery = platform === "ios-recorded";
const device = platform.startsWith("ios")
    ? "F2ACCCB5-E5B3-426F-B962-955A113D4EF4"
    : "3ADF3A87-AD51-40F6-8BCB-DAD392EF2378",
  bundle = "com.dbakp.taskfold.workflowteststeameditbridge",
  products =
    "/tmp/taskfold-prepared-undo-signed-ios-build/Build/Products/Debug-iphonesimulator";
const report = {
  platform,
  checks: {},
  genuineAuth: false,
  actualLocalStorage: true,
  fullSchemaParity: false,
  deployed: false,
  normalUseEnabled: false,
};
const check = (name, a, b = true) => {
  assert.deepEqual(a, b, name);
  report.checks[name] = true;
  console.log("passed:", name);
};
let pg, storage, http, configPath, configText, initialState;
const states = async () =>
  JSON.parse(
    (await exec("xcrun", ["simctl", "list", "devices", "--json"])).stdout,
  ).devices;
async function currentHome() {
  const root = homedir() + "/Library/Developer/CoreSimulator/Devices/" +
    device + "/data/Containers/Data/Application";
  const matches = [];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    try {
      const path = root + "/" + entry.name;
      const metadata = await exec("plutil", [
        "-extract",
        "MCMMetadataIdentifier",
        "raw",
        "-o",
        "-",
        path + "/.com.apple.mobile_container_manager.metadata.plist",
      ]);
      if (metadata.stdout.trim() === bundle) matches.push(path);
    } catch { /* Other containers do not belong to this fixture. */ }
  }
  assert.equal(
    matches.length,
    1,
    "Exactly one owned native app container is required",
  );
  return matches[0];
}
try {
  await exec("python3", ["Scripts/check_test_storage.py", "--path", "/tmp"]);
  ({ pg, storage } = await createTaskFileProviderDatabase());
  for (
    const file of [
      ...audioProjectLedgerDependencies,
      audioProjectCustodyMigration,
    ]
  ) await pg.raw(await migrationSQL(file));
  await pg.raw(
    await migrationSQL("20261102175200_reviewed_audio_generation_restore.sql"),
  );
  await pg.raw(
    await migrationSQL("20261102181442_audio_lifecycle_native_review.sql"),
  );
  await pg.raw(await migrationSQL("20261102194929_recording_restore_recovery_fence.sql"));
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
  if (platform !== "service") {
    await pg.raw(
      "update taskfold_private.audio_comment_config set restoration_enabled=true",
    );
  }
  http = await createAudioTeamNativeHttp(pg, storage, users.actor, { expiredRecovery, recordedRecovery });
  if (platform === "service") {
    http.faults.losePublicationReply = false;
    const serviceCall = (action, body) =>
      fetch(http.url + "/functions/v1/audio-comments?action=" + action, {
        method: "POST",
        headers: {
          Authorization: "Bearer " + http.token,
          apikey: "synthetic-public",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(25000),
        redirect: "error",
      });
    const media = await readFile(
      new URL(
        "../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
        import.meta.url,
      ),
    );
    const intent = {
      version: 1,
      account,
      operation_id: randomUUID(),
      comment_id: randomUUID(),
      asset_id: randomUUID(),
      target: {
        task_id: task,
        task_generation: generation,
        project_id: project,
      },
      caption: "Native provider preflight",
      audio: {
        version: 1,
        mime_type: "audio/mp4",
        byte_count: media.length,
        duration_ms: 1000,
        sha256: createHash("sha256").update(media).digest("hex"),
      },
    };
    const response = await serviceCall("publish", {
      intent,
      audio_base64: media.toString("base64"),
    });
    check(
      "production handler publishes using real Storage",
      response.status,
      200,
    );
    report.serviceReceipt = await response.json();
    const download = await serviceCall("download", {
      comment_id: intent.comment_id,
    });
    check("gateway download succeeds", download.status, 200);
    check(
      "native proxy preserves verified checksum header",
      download.headers.get("X-Audio-SHA256"),
      intent.audio.sha256,
    );
    check(
      "real provider bytes match",
      Buffer.from(await download.arrayBuffer()),
      media,
    );
    const remove = await serviceCall("remove", {
      comment_id: intent.comment_id,
    });
    check("current author removes", remove.status, 200);
  } else {
    const host = "/tmp/taskfold-owner-review-ios-host";
    const replacements = {
      "com.dbakp.taskfold.task":
        "com.dbakp.taskfold.workflowteststeameditbridge.task",
      "com.taskfold.ios.session":
        "com.taskfold.workflowteststeameditbridge.session",
      "com.taskfold.recovery.v1":
        "com.taskfold.workflowteststeameditbridge.recovery",
      "group.com.dbakp.taskfold":
        "group.com.dbakp.taskfold.workflowteststeameditbridge",
    };
    report.sourceSHA256 = {};
    for (
      const file of [
        "Taskfold/AudioCommentNativeFixture.swift",
        "Taskfold/AudioCommentCapture.swift",
        "Taskfold/Core/Store.swift",
        "Taskfold/Core/TeamProjectAccess.swift",
        "Taskfold/Core/Backend.swift",
        "Taskfold/Views/TeamTaskDeletionReview.swift",
        "Taskfold/Core/AudioCommentPublishing.swift",
        "Taskfold/Views/TaskEditor.swift",
        "Taskfold/Views/AudioCommentConversationView.swift",
        "Taskfold/Views/AudioCommentPublicationView.swift",
        "TaskfoldUITests/AudioCommentUITests.swift",
      ]
    ) {
      const source = await readFile(
        new URL("../../" + file, import.meta.url),
        "utf8",
      );
      let expected = source;
      for (const [original, isolated] of Object.entries(replacements)) {
        expected = expected.replaceAll(original, isolated);
      }
      check(
        "compiled owning source matches " + file,
        await readFile(host + "/" + file, "utf8"),
        expected,
      );
      report.sourceSHA256[file] = createHash("sha256").update(source).digest(
        "hex",
      );
    }
    for (const app of ["Taskfold.app", "TaskfoldUITests-Runner.app"]) {
      await exec("codesign", [
        "--verify",
        "--deep",
        "--strict",
        products + "/" + app,
      ]);
    }
    check(
      "exact isolated app identifier",
      (await exec("plutil", [
        "-extract",
        "CFBundleIdentifier",
        "raw",
        "-o",
        "-",
        products + "/Taskfold.app/Info.plist",
      ])).stdout.trim(),
      bundle,
    );
    initialState = Object.values(await states()).flat().find((x) =>
      x.udid === device
    )?.state;
    assert(["Shutdown", "Booted"].includes(initialState));
    if (initialState === "Shutdown") {
      await exec("xcrun", ["simctl", "boot", device]);
      await exec("xcrun", ["simctl", "bootstatus", device, "-b"], {
        timeout: 120000,
      });
    }
    await exec("xcrun", [
      "simctl",
      "install",
      device,
      products + "/Taskfold.app",
    ], { timeout: 60000 });
    const home = (await exec("xcrun", [
      "simctl",
      "get_app_container",
      device,
      bundle,
      "data",
    ])).stdout.trim();
    assert(home.includes("/" + device + "/data/Containers/Data/Application/"));
    configPath = home + "/Documents/taskfold-audio-team-native.json";
    configText = JSON.stringify({
      schema: "1",
      account,
      url: http.url + "/",
      token: http.token,
    });
    await writeFile(configPath, configText, { mode: 0o600, flag: "wx" });
    const result = output.replace(/\.json$/, ".xcresult"),
      log = output.replace(/\.json$/, ".log"),
      test = expiredRecovery ? "testTeamRecordingNativeExpiredRecovery" : recordedRecovery ? "testTeamRecordingNativeRecordedRecovery" : "testTeamRecordingNativeServiceRecoveryDownloadAndRemoval";
    const command = [
      "-project",
      "/tmp/taskfold-owner-review-ios-host/Taskfold.xcodeproj",
      "-scheme",
      "Taskfold",
      "-configuration",
      "Debug",
      "-derivedDataPath",
      "/tmp/taskfold-prepared-undo-signed-ios-build",
      "-destination",
      "platform=iOS Simulator,id=" + device,
      "-parallel-testing-enabled",
      "NO",
      "-collect-test-diagnostics",
      "never",
      "-only-testing:TaskfoldUITests/TaskfoldUITests/" + test,
      "-resultBundlePath",
      result,
      "test-without-building",
    ];
    const stream = createWriteStream(log);
    await new Promise((r, j) => {
      stream.once("open", r);
      stream.once("error", j);
    });
    try {
      const child = spawn("xcodebuild", command, {
        stdio: ["ignore", stream, stream],
      });
      report.xcodeExitCode = await new Promise((r, j) => {
        child.once("exit", r);
        child.once("error", j);
      });
    } finally {
      await new Promise((r) => stream.end(r));
    }
    report.nativeSummary = JSON.parse(
      (await exec("xcrun", [
        "xcresulttool",
        "get",
        "test-results",
        "summary",
        "--path",
        result,
        "--compact",
      ])).stdout,
    );
    check("one native case accepted without skip", [
      report.xcodeExitCode,
      report.nativeSummary.passedTests,
      report.nativeSummary.failedTests,
      report.nativeSummary.skippedTests,
    ], [0, 1, 0, 0]);
    const liveHome = await currentHome();
    report.uniqueOwnedContainerVerified = true;
    const cache = JSON.parse(
      await readFile(
        liveHome + "/Library/Application Support/Taskfold/" + account + ".json",
        "utf8",
      ),
    );
    const row = cache.tables.tasks.find((x) => x.id === task);
    const restoredGeneration = await pg.scalar(
      `select to_jsonb(task_generation) from public.tasks where id=${
        lit(task)
      }`,
    );
    check(
      "native signed-in cache contains actual restored generation",
      row.task_generation,
      restoredGeneration,
    );
    check(
      "native Undo uses a fresh task generation",
      restoredGeneration !== generation,
    );
    check(
      expiredRecovery || recordedRecovery ? "native deletion and restoration replay reach SQL" : "native actual deletion and Undo reached SQL once each",
      ["delete", "restore"].map((a) =>
        http.requests.filter((x) => x.action === "task_" + a).length
      ),
      expiredRecovery || recordedRecovery ? [1, 2] : [1, 1],
    );
    check(
      expiredRecovery ? "native lifecycle carries separately explicit retention and omission policies" : "native lifecycle retains frozen recording acknowledgement",
      http.requests.filter((x) =>
        x.action === "task_delete" || x.action === "task_restore"
      ).every((x) =>
        x.ack?.policy === (expiredRecovery && x.action === "task_restore" ? "expired_recordings_omitted_v1" : "published_restore_v1") && x.ack?.count === 1 &&
        x.ack?.retention_days === 30 && Object.keys(x.ack).length === 3
      ),
    );

    check(
      "native cache read actual SQL content",
      row.description,
      original.description,
    );
    check("native cache has no queued edits", cache.pending, []);
    check(
      "normal sync reads every required table",
      workspaceTables.every((t) => (http.workspace.counts.tables[t] ?? 0) > 0),
    );
    check(
      "confirmation handoffs refresh actual SQL",
      http.workspace.counts.boundary >= 6,
    );
    check("workspace adapter has no errors", http.workspace.counts.errors, []);
    check(
      "native deletion review reads actual recording count",
      http.requests.some((x) =>
        x.action === "lifecycle_review" && x.recordingCount === 1
      ),
    );
    check(
      "lost committed publication reply injected once",
      http.requests.filter((x) =>
        x.action === "publish" && x.responseStatus === 200 &&
        x.deliveredStatus === 503
      ).length,
      1,
    );
    check(
      "Check publication uses metadata without resending media",
      http.requests.filter((x) => x.action === "publish").length,
      1,
    );
    check(
      "native owner status reached production gateway",
      http.requests.some((x) =>
        x.action === "resolve" && x.responseStatus === 200
      ),
    );
    if (recordedRecovery) {
      const restores = http.requests.filter((x) => x.action === "task_restore"), inspections = http.requests.filter((x) => x.action === "restore_recovery_inspect");
      check("applied original Undo loses exactly one reply", restores.map((x) => x.deliveredStatus), [503, 200]);
      check("recorded confirmation uses the exact original intent", restores[0].command, restores[1].command);
      check("recorded review and reopening observe actual receipt", inspections.map((x) => x.state), ["recorded", "recorded"]);
      check("recorded confirmation never closes original", http.requests.filter((x) => x.action === "restore_recovery_close"), []);
      check("recorded confirmation creates no closure ledger row", await pg.scalar("select count(*)::int from taskfold_private.audio_restore_closures"), 0);
      check("recorded confirmation applies one restoration only", await pg.scalar("select count(*)::int from taskfold_private.team_task_edits where operation='restore'"), 1);
    }
    if (expiredRecovery) {
      const closed = http.requests.filter((x) => x.action === "restore_recovery_close"), restored = http.requests.filter((x) => x.action === "task_restore");
      check("Cancel and cold return do not close original Undo", closed.length, 1);
      check("actual original Undo was closed before task-only restoration", closed[0].state, "closed");
      check("expired retention uses real cleanup", http.faults.expiryProof.actualRetentionExpired && http.faults.expiryProof.actualFencedCleanup.purged === 1);
      check("committed task-only reply is lost exactly once", restored.map((x) => x.deliveredStatus), [503, 200]);
      check("cold task-only retry keeps frozen request values", restored[0].command, restored[1].command);
      check("task-only choice uses a different request from closed Undo", restored[0].requestID !== closed[0].requestID);
      check("original retained-recording retry is refused after expiry", http.requests.some((x) => x.action === "task_restore_refused" && x.code === "PT409" && x.ack?.policy === "published_restore_v1"));
      check("task-only recovery never downloads or resends expired media", http.requests.filter((x) => ["download", "remove"].includes(x.action)), []);
      const closureCount = await pg.scalar("select count(*)::int from taskfold_private.audio_restore_closures");
      check("one durable terminal closure", closureCount, 1);
      const originalOps = await pg.scalar("select count(*)::int from taskfold_private.team_task_edits where operation='restore'");
      check("one actual task restoration despite lost reply", originalOps, 1);
      const list = await http.audio.call("list", { task_id: task, task_generation: restoredGeneration, project_id: project });
      check("task-only restored list is authorized", list.status, 200);
      check("restored task has no expired published recordings", (await list.json()).items, []);
    } else check(
      "native playback downloaded through gateway",
      http.requests.some((x) =>
        x.action === "download" && x.responseStatus === 200
      ),
    );
    if (!expiredRecovery) check(
      "native removal reached gateway",
      http.requests.some((x) =>
        x.action === "remove" && x.responseStatus === 200
      ),
    );
  }
  const ledger = await pg.scalar(
    "select coalesce(jsonb_agg(to_jsonb(r)),'[]') from taskfold_private.audio_comment_publications r",
  );
  check("one immutable publication identity", ledger.length, 1);
  const publication = ledger[0];
  check(
    "actor is current editor rather than task creator",
    publication.author_id,
    account,
  );
  check("recording retired by actual removal or expired cleanup", publication.state, expiredRecovery ? "purged" : "retired");
  check("provider received one media upload", http.audio.state.uploads, 1);
  check(
    "task content remains exact apart from certified generation renewal",
    await pg.scalar(
      `select to_jsonb(t) from public.tasks t where id=${lit(task)}`,
    ),
    platform === "service" ? original : {
      ...original,
      task_generation: await pg.scalar(
        `select to_jsonb(task_generation) from public.tasks where id=${
          lit(task)
        }`,
      ),
    },
  );
  await pg.raw(
    "update taskfold_private.audio_comment_publications set cleanup_after=clock_timestamp()-interval '1 second' where state='retired'",
  );
  const maintained = await http.audio.maintain();
  report.maintenance = await maintained.json();
  check("maintenance request succeeds", maintained.status, 200);
  const terminal = await pg.scalar(
    `select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${
      lit(publication.operation_id)
    }`,
  );
  report.terminal = terminal;
  check(
    "actual fenced cleanup releases ledger quota",
    terminal.state,
    "purged",
  );
  check(
    "removed bytes absent from real provider",
    (await storage.request(
      "/object/authenticated/taskfold-audio-v1/" + publication.object_name,
    )).ok,
    false,
  );
  report.checkCount = Object.keys(report.checks).length;
} catch (error) {
  report.error = { message: error.message, code: error.code ?? null };
  throw error;
} finally {
  if (http) {
    report.gatewayRequests = http.requests;
    report.workspace = http.workspace.counts;
    report.provider = http.audio.state.providerResults;
    report.gatewayErrors = http.audio.state.errors;
    if (expiredRecovery || recordedRecovery) report.recoveryFaults = http.faults;
  }
  report.checkCount = Object.keys(report.checks).length;
  const errors = [];
  if (configPath) {
    try {
      configPath = (await currentHome()) +
        "/Documents/taskfold-audio-team-native.json";
      if ((await readFile(configPath, "utf8")) === configText) {
        await unlink(configPath);
        report.configRemoved = true;
      } else errors.push("owned config changed");
    } catch (e) {
      if (e.code !== "ENOENT") errors.push(e.message);
      else report.configAbsentOnCleanup = true;
    }
  }
  for (
    const [resource, key] of [
      [http, "httpClosed"],
      [storage, "storageRemoved"],
      [pg, "databaseRemoved"],
    ]
  ) {
    if (resource) {
      try {
        report[key] = await resource.close();
      } catch (e) {
        errors.push(e.message);
      }
    }
  }
  if (platform !== "service" && initialState) {
    try {
      const current = Object.values(await states()).flat().find((x) =>
        x.udid === device
      )?.state;
      if (current === "Booted") {
        await exec("xcrun", ["simctl", "terminate", device, bundle]).catch(
          () => {},
        );
        if (initialState === "Shutdown") {
          await exec("xcrun", ["simctl", "shutdown", device]);
        }
      }
      report.ownedSimulatorRestored = true;
    } catch (e) {
      errors.push(e.message);
    }
  }
  report.cleanupErrors = errors;
  await writeFile(output, JSON.stringify(report, null, 2) + "\n");
}
assert.deepEqual(report.cleanupErrors, []);
console.log(
  JSON.stringify({
    checks: report.checkCount,
    storageRemoved: report.storageRemoved,
    databaseRemoved: report.databaseRemoved,
  }),
);
