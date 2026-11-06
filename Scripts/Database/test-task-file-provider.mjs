import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { literal as lit } from "./postgres-fixture.mjs";
import { storageImage } from "./storage-provider-fixture.mjs";
import { createTaskFileProviderHttp } from "./task-files-provider-http-fixture.mjs";
import { createTaskFileProviderDatabase } from "./task-file-provider-schema.mjs";
if (Number(process.versions.node.split(".")[0]) < 22) {
  throw Error(
    "This provider fixture requires Node.js 22 or newer before starting any containers.",
  );
}
const report = {
  checks: {},
  providerBytesTested: false,
  providerImage: storageImage,
  hostedChanges: false,
  fullStackAuthAccepted: false,
};
let pg, storage, http;
const check = (name, a, b = true) => {
  assert.deepEqual(a, b, name);
  report.checks[name] = true;
  console.log("passed:", name);
};
try {
  ({ pg, storage } = await createTaskFileProviderDatabase());
  check(
    "real Storage schema owns metadata",
    await pg.scalar(
      "select to_jsonb(exists(select 1 from information_schema.columns where table_schema='storage' and table_name='objects' and column_name='version'))",
    ),
  );
  check(
    "actual provider starts empty",
    await pg.scalar("select count(*) from storage.objects"),
    0,
  );
  report.storageSchemaMigrations = await pg.scalar(
    "select jsonb_agg(name order by id) from storage.migrations",
  );
  report.baselineAdvisors = await pg.advisors();
  const users = Object.fromEntries(
    ["owner", "viewer", "outside"].map(
      (k) => [k, { id: randomUUID(), session: randomUUID() }],
    ),
  );
  for (const u of Object.values(users)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${
        lit(u.id + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${
        lit(u.id)
      });insert into public.profiles(user_id) values(${lit(u.id)})`,
    );
  }
  const team = randomUUID(), project = randomUUID(), owner = users.owner;
  const json = (v) => lit(JSON.stringify(v)) + "::jsonb";
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(owner.id)
    },'Provider workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(owner.id)},'admin'),(${lit(team)},${
      lit(users.viewer.id)
    },'guest');insert into public.projects(id,user_id,name) values(${
      lit(project)
    },${
      lit(owner.id)
    },'Provider files');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
      lit(project)
    },${
      lit(team)
    },'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${
      lit(project)
    },${lit(team)},${
      lit(users.viewer.id)
    },'viewer');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_task_types_enabled=true`,
  );
  http = await createTaskFileProviderHttp(pg, storage, users);
  const seed = async (bytes = Buffer.from("Real provider workshop notes")) => {
    await pg.raw(
      "update taskfold_private.task_file_uploads set created_at=clock_timestamp()-interval '2 minutes'",
    );
    const id = randomUUID();
    await pg.raw(
      `insert into public.tasks(id,user_id,project_id,title,subtasks,attachments) values(${
        lit(id)
      },${lit(owner.id)},${lit(project)},'Synthetic provider proof','[]','[]')`,
    );
    const task = await pg.scalar(
      `select to_jsonb(t) from public.tasks t where id=${lit(id)}`,
    );
    const intent = {
      operation_id: randomUUID(),
      target: {
        team_id: team,
        project_id: project,
        task_id: id,
        task_generation: task.task_generation,
      },
      name: "Provider proof.txt",
      type: "text/plain",
      byte_count: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    };
    return {
      intent,
      bytes,
      body: { intent, bytes_base64: bytes.toString("base64") },
    };
  };
  const saved = (i) =>
    pg.scalar(
      `select to_jsonb(u) from taskfold_private.task_file_uploads u where operation_id=${
        lit(i.operation_id)
      }`,
    );
  const attachments = (i) =>
    pg.scalar(
      `select attachments from public.tasks where id=${lit(i.target.task_id)}`,
    );
  const download = (i, receipt) => ({
    object_id: receipt.attachment.storage_object_id,
    task_id: i.target.task_id,
    task_generation: i.target.task_generation,
  });
  const first = await seed();
  check(
    "SQL publishing defaults off",
    (await http.call("publish", first.body)).status,
    503,
  );
  check("disabled publication makes no provider POST", http.counts.uploads, 0);
  await pg.raw(
    "update taskfold_private.task_file_upload_config set enabled=true",
  );
  check(
    "viewer cannot upload",
    (await http.call("publish", first.body, "viewer")).status,
    404,
  );
  check(
    "outside account cannot upload",
    (await http.call("publish", first.body, "outside")).status,
    404,
  );
  let answer = await http.call("publish", first.body);
  check("real provider upload publishes", answer.status, 200);
  const published = answer.json().receipt;
  check(
    "published receipt names exact operation",
    published.operation_id,
    first.intent.operation_id,
  );
  const allocation = await saved(first.intent);
  const stored = await storage.request(
    "/object/authenticated/task-attachments/" + allocation.object_name,
  );
  check(
    "provider independently reads exact committed bytes",
    Buffer.from(await stored.arrayBuffer()),
    first.bytes,
  );
  report.providerBytesTested = true;
  check(
    "provider metadata matches immutable published identity",
    await pg.scalar(
      `select to_jsonb(id) from storage.objects where bucket_id='task-attachments' and name=${
        lit(allocation.object_name)
      }`,
    ),
    published.attachment.storage_object_id,
  );
  check(
    "exactly one attachment appended",
    (await attachments(first.intent)).length,
    1,
  );
  answer = await http.call(
    "download",
    download(first.intent, published),
    "viewer",
  );
  check("current viewer downloads actual bytes", answer.status, 200);
  check("gateway readback verifies exact bytes", answer.bytes, first.bytes);
  check(
    "download carries verified hash",
    answer.headers.get("x-file-sha256"),
    first.intent.sha256,
  );
  const postCount = http.counts.uploads;
  answer = await http.call("publish", first.body);
  check(
    "same-operation retry returns immutable receipt",
    answer.json().receipt,
    published,
  );
  check(
    "published retry never writes provider twice",
    http.counts.uploads,
    postCount,
  );
  // Positive control: a real authenticated Storage request must read an
  // ordinary permitted prefix, so namespace-denial checks cannot pass merely
  // because the fixture's user JWT or Auth helper is broken.
  const ordinaryPath = owner.id + "/ordinary-provider-control.txt";
  const ordinaryWrite = await storage.request(
    "/object/task-attachments/" + ordinaryPath,
    {
      method: "POST",
      headers: { "Content-Type": "text/plain", "x-upsert": "false" },
      body: first.bytes,
    },
  );
  check("ordinary provider control is created", ordinaryWrite.status, 200);
  const ordinaryRead = await storage.request(
    "/object/authenticated/task-attachments/" + ordinaryPath,
    {},
    http.tokens.owner,
  );
  check(
    "authenticated owner can read an ordinary allowed prefix",
    ordinaryRead.status,
    200,
  );
  check(
    "ordinary authenticated read returns exact control bytes",
    Buffer.from(await ordinaryRead.arrayBuffer()),
    first.bytes,
  );
  const ordinaryOutside = await storage.request(
    "/object/authenticated/task-attachments/" + ordinaryPath,
    {},
    http.tokens.outside,
  );
  check(
    "another account cannot read the ordinary owner prefix",
    [400, 403, 404].includes(ordinaryOutside.status),
  );
  const ordinaryDelete = await storage.request("/object/task-attachments", {
    method: "DELETE",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prefixes: [ordinaryPath] }),
  });
  check(
    "ordinary test control is removed through provider API",
    ordinaryDelete.status,
    200,
  );
  for (const name of ["owner", "viewer"]) {
    const direct = await storage.request(
      "/object/authenticated/task-attachments/" + allocation.object_name,
      {},
      http.tokens[name],
    );
    check(
      name + " cannot bypass gateway through real Storage",
      [400, 403, 404].includes(direct.status),
    );
    await direct.arrayBuffer();
  }
  const anon = await storage.request(
    "/object/authenticated/task-attachments/" + allocation.object_name,
    {},
    storage.anon,
  );
  check(
    "anonymous provider access is denied",
    [400, 403, 404].includes(anon.status),
  );
  await anon.arrayBuffer();
  check(
    "outsider cannot download through gateway",
    (await http.call("download", download(first.intent, published), "outside"))
      .status,
    404,
  );
  await pg.raw(
    `update auth.sessions set not_after=now()-interval '1 minute' where id=${
      lit(users.viewer.session)
    }`,
  );
  check(
    "expired session cannot download provider bytes",
    (await http.call("download", download(first.intent, published), "viewer"))
      .status,
    404,
  );
  await pg.raw(
    `update auth.sessions set not_after=null where id=${
      lit(users.viewer.session)
    }`,
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where project_id=${
      lit(project)
    } and user_id=${lit(users.viewer.id)}`,
  );
  check(
    "access withdrawal blocks provider download",
    (await http.call("download", download(first.intent, published), "viewer"))
      .status,
    404,
  );
  await pg.raw(
    `insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${
      lit(project)
    },${lit(team)},${lit(users.viewer.id)},'viewer')`,
  );
  const lost = await seed();
  http.faults.loseFinalize = true;
  check(
    "lost final reply is uncertain to client",
    (await http.call("publish", lost.body)).status,
    503,
  );
  const afterLost = http.counts.uploads;
  answer = await http.call("publish", lost.body);
  check("lost final reply safely resolves", answer.status, 200);
  check(
    "lost final reply does not duplicate provider upload",
    http.counts.uploads,
    afterLost,
  );
  check(
    "lost final reply appends once",
    (await attachments(lost.intent)).length,
    1,
  );
  const unacked = await seed();
  http.faults.loseUpload = true;
  check(
    "lost upload acknowledgement leaves uncertain result",
    (await http.call("publish", unacked.body)).status,
    503,
  );
  const beforeReconcile = http.counts.uploads;
  answer = await http.call("publish", unacked.body);
  check("retry reconciles real stored bytes and metadata", answer.status, 200);
  check(
    "unresolved writer retry does not POST again",
    http.counts.uploads,
    beforeReconcile,
  );
  const abandoned = await seed();
  http.faults.failFinalize = true;
  check(
    "interrupted finalization keeps reserved provider file",
    (await http.call("publish", abandoned.body)).status,
    503,
  );
  check(
    "sender can stop a stored unfinalized file",
    (await http.call("cancel", { operation_id: abandoned.intent.operation_id }))
      .json().receipt.state,
    "cancelled",
  );
  answer = await http.call("maintenance", {});
  check("real cleanup request succeeds", answer.status, 200);
  report.firstCleanup = answer.json();
  report.transportCounts = http.counts;
  report.cleanupAllocation = await saved(abandoned.intent);
  const absent = await storage.request(
    "/object/authenticated/task-attachments/" +
      report.cleanupAllocation.object_name,
  );
  report.absence = { status: absent.status, body: await absent.text() };
  check(
    "closed stored upload is deleted and quota released",
    (await saved(abandoned.intent)).provider_cleanup_confirmed_at !== null,
  );
  check(
    "actual provider metadata is gone",
    await pg.scalar(
      `select count(*) from storage.objects where bucket_id='task-attachments' and name=${
        lit((await saved(abandoned.intent)).object_name)
      }`,
    ),
    0,
  );
  check(
    "published object survives maintenance",
    (await storage.request(
      "/object/authenticated/task-attachments/" + allocation.object_name,
    )).status,
    200,
  );
  const lostDelete = await seed();
  http.faults.failFinalize = true;
  check(
    "second interrupted finalization retains original allocation",
    (await http.call("publish", lostDelete.body)).status,
    503,
  );
  await http.call("cancel", { operation_id: lostDelete.intent.operation_id });
  http.faults.loseDelete = true;
  answer = await http.call("maintenance", {});
  check(
    "lost delete acknowledgement remains unresolved",
    answer.json().unresolved,
    1,
  );
  check(
    "lost delete acknowledgement does not release quota",
    (await saved(lostDelete.intent)).provider_cleanup_confirmed_at,
    null,
  );
  const deletedAllocation = await saved(lostDelete.intent);
  check(
    "lost acknowledgement still removed actual metadata",
    await pg.scalar(
      `select count(*) from storage.objects where bucket_id='task-attachments' and name=${
        lit(deletedAllocation.object_name)
      }`,
    ),
    0,
  );
  const deletesBeforeRetry = http.counts.deletes;
  await pg.raw(
    `update taskfold_private.task_file_cleanup_claims set expires_at=clock_timestamp()-interval '1 second' where operation_id=${
      lit(lostDelete.intent.operation_id)
    }`,
  );
  answer = await http.call("maintenance", {});
  check(
    "fresh claim confirms actual provider absence after lost reply",
    answer.json().purged,
    1,
  );
  check(
    "absence retry does not delete again",
    http.counts.deletes,
    deletesBeforeRetry,
  );
  check(
    "lost delete recovery durably releases quota",
    (await saved(lostDelete.intent)).provider_cleanup_confirmed_at !== null,
  );
  const emptyWriter = await seed();
  const directCommand = async (action, body) => {
    const r = await pg.value(
      `public.taskfold_task_file_command(${lit(action)},${lit(owner.id)},${
        lit(owner.session)
      },${json(body)})`,
    );
    assert(!r.code, r.code);
    return r.value;
  };
  check(
    "unresolved-writer reservation is admitted",
    (await directCommand("reserve_fenced", emptyWriter.intent)).status,
    "reserved",
  );
  check(
    "one unresolved write is admitted",
    (await directCommand("upload_begin", {
      operation_id: emptyWriter.intent.operation_id,
    })).status,
    "upload",
  );
  await http.call("cancel", { operation_id: emptyWriter.intent.operation_id });
  answer = await http.call("maintenance", {});
  check(
    "actual provider absence never settles a still-open writer",
    answer.json().unresolved,
    1,
  );
  check(
    "absent open writer keeps its quota allocation",
    (await saved(emptyWriter.intent)).provider_cleanup_confirmed_at,
    null,
  );
  const large = await seed(Buffer.alloc(5 * 1024 * 1024, 255));
  large.intent.type = "application/octet-stream";
  large.intent.name = "Provider proof.bin";
  answer = await http.call("publish", large.body);
  check(
    "full five MiB binary publishes through real provider",
    answer.status,
    200,
  );
  const largeReceipt = answer.json().receipt;
  answer = await http.call(
    "download",
    download(large.intent, largeReceipt),
    "viewer",
  );
  check("full five MiB download succeeds", answer.status, 200);
  check("full binary round trip is exact", answer.bytes, large.bytes);
  report.maximumFileBytes = large.bytes.length;
  answer = await http.call(
    "download",
    download(first.intent, published),
    "viewer",
  );
  check(
    "published file survives all cleanup recovery",
    answer.bytes,
    first.bytes,
  );
  report.transportCounts = http.counts;
  report.advisors = await pg.advisors();
  const baseline = new Set(
    report.baselineAdvisors.result.map((x) => x.cache_key),
  );
  check(
    "no additional advisor findings",
    report.advisors.result.filter((x) => !baseline.has(x.cache_key)),
    [],
  );
} catch (error) {
  report.error = { message: error.message, code: error.code };
  throw error;
} finally {
  const failures = [];
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
      } catch (error) {
        failures.push({ resource: key, message: error.message });
      }
    }
  }
  if (failures.length) report.cleanupErrors = failures;
  report.checkCount = Object.keys(report.checks).length;
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
}
if (report.cleanupErrors?.length) {
  throw Error("Owned provider fixture cleanup failed");
}
console.log(
  JSON.stringify({
    checks: report.checkCount,
    storageRemoved: report.storageRemoved,
    databaseRemoved: report.databaseRemoved,
  }),
);
