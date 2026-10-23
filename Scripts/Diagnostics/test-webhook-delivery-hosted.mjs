// Actual Auth -> Edge -> PostgREST -> encrypted outbox -> pinned TLS receiver.
// Refuses main/data-bearing branches. Only fixed synthetic accounts/tasks.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import {
  cp,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const [connectionPath, schemaReceiptPath, output, mode] = process.argv.slice(2);
assert(mode === undefined || mode === "--scheduler", "Unknown fixture mode");
const scheduled = mode === "--scheduler";
assert(
  connectionPath && schemaReceiptPath && output,
  "Supply private connection, schema receipt and output",
);
const parent = "zqxflydiyfjeedqvyova",
  exec = promisify(execFile),
  repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
assert(
  ((await stat(connectionPath)).mode & 0o077) === 0,
  "Owner-private connection required",
);
const config = JSON.parse(await readFile(connectionPath, "utf8")),
  origin = config.SUPABASE_URL,
  project = new URL(origin).hostname.split(".")[0];
assert(
  project !== parent && /^[a-z]{20}$/.test(project) &&
    origin === `https://${project}.supabase.co`,
  "Refuse primary or unrelated host",
);
async function cli(args) {
  try {
    return (await exec("supabase", args, {
      timeout: 90000,
      maxBuffer: 1048576,
    })).stdout;
  } catch {
    throw Error("Owned preview CLI action failed");
  }
}
const branch = JSON.parse(
  await cli(["branches", "list", "--project-ref", parent, "--output", "json"]),
).find((b) => b.project_ref === project);
assert(
  branch && !branch.is_default && !branch.persistent &&
    branch.with_data === false &&
    branch.name.startsWith("codex-webhook-delivery-acceptance-"),
  "Refuse unowned branch",
);
const schema = JSON.parse(await readFile(schemaReceiptPath, "utf8"));
assert(schema.project === project && schema.branchId === branch.id);
for (const [file, hash] of Object.entries(schema.migrationHashes)) {
  assert(
    createHash("sha256").update(
      await readFile(join(repo, "supabase/migrations", file)),
    ).digest("hex") === hash,
    "Applied schema source differs",
  );
}
const result = {
  date: new Date().toISOString(),
  project,
  branchId: branch.id,
  checks: {},
  realTasksChanged: 0,
  mainChanged: false,
  scheduledInvocationClaimed: false,
  sourceHashes: {},
  cleanup: { users: false, functions: false, secrets: false, files: false },
};
for (
  const directory of [
    "supabase/functions/automation-webhooks",
    "supabase/functions/automation-keys",
    "supabase/functions/automation-tasks",
    "supabase/functions/_shared",
    "supabase/functions/dispatch-webhooks",
    "Scripts/Diagnostics",
  ]
) {
  const files = await readdir(join(repo, directory), { withFileTypes: true });
  for (const file of files) {
    if (
      !file.isFile() ||
      (directory === "Scripts/Diagnostics" &&
        ![
          "test-webhook-delivery-hosted.mjs",
          "prepare-webhook-hosted.mjs",
          "webhook-hosted-receiver.ts",
          "webhook-hosted-receiver.sql",
          "webhook-hosted-base.sql",
        ].includes(file.name))
    ) continue;
    const path = directory + "/" + file.name;
    result.sourceHashes[path] = createHash("sha256").update(
      await readFile(join(repo, path)),
    ).digest("hex");
  }
}
const check = (name, value) => {
  result.checks[name] = !!value;
  assert(value, name);
};
const anon = config.SUPABASE_ANON_KEY,
  service = config.SUPABASE_SERVICE_ROLE_KEY,
  controlToken = randomBytes(32).toString("hex"),
  secret = randomBytes(32),
  master = randomBytes(32).toString("hex");
let workerToken = randomBytes(32).toString("hex");
const stage = await mkdtemp(join(tmpdir(), "taskfold-webhook-hosted-")),
  users = [],
  deployed = [];
async function database(sql) {
  const target = new URL(config.POSTGRES_URL);
  assert(
    ["postgres:", "postgresql:"].includes(target.protocol) &&
      ((target.hostname === `db.${project}.supabase.co` &&
        target.username === "postgres") ||
        (/^aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com$/.test(
          target.hostname,
        ) && decodeURIComponent(target.username) === `postgres.${project}`)),
    "Database must match owned preview",
  );
  const file = join(stage, "private-query.sql");
  await writeFile(file, sql, { mode: 0o600 });
  return JSON.parse(
    await cli([
      "db",
      "query",
      "--db-url",
      config.POSTGRES_URL,
      "--file",
      file,
      "--output",
      "json",
    ]),
  ).rows;
}
const receiverSlug = "webhook-acceptance-receiver",
  environment = {
    TASKFOLD_AUTOMATION_FORWARDED_FOR_MODE: "supabase-cloudflare-v1",
    TASKFOLD_WEBHOOK_MASTER_KEYS: JSON.stringify({ "acceptance-v1": master }),
    TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION: "acceptance-v1",
    TASKFOLD_WEBHOOK_WORKER_TOKEN: workerToken,
    TASKFOLD_WEBHOOK_DISPATCH_ENABLED: "1",
    TASKFOLD_WEBHOOK_ACCEPTANCE_PROJECT: project,
    TASKFOLD_WEBHOOK_ACCEPTANCE_TOKEN: controlToken,
    TASKFOLD_WEBHOOK_ACCEPTANCE_SECRET: secret.toString("base64url"),
  };
async function api(path, token, body, method = "POST", key = anon, extra = {}) {
  const r = await fetch(origin + path, {
    method,
    redirect: "error",
    signal: AbortSignal.timeout(65000),
    headers: {
      apikey: key,
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
      ...extra,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  assert(Buffer.byteLength(text) <= 4000000, "Response exceeds fixture bound");
  let value;
  try {
    value = text ? JSON.parse(text) : null;
  } catch {
    value = null;
  }
  return { status: r.status, value };
}
const native = (user, action, body = {}) =>
  api(
    "/functions/v1/automation-webhooks",
    user.token,
    { action, body },
    "POST",
    anon,
    { "X-Taskfold-Automation": "1" },
  );
const task = (key, action, body = {}) =>
  api(
    "/functions/v1/automation-tasks" +
      (["create", "update", "complete", "reopen", "delete"].includes(action)
        ? "/write"
        : ""),
    key,
    { action, body },
    "POST",
    anon,
    {
      "X-Taskfold-Automation": "1",
    },
  );
const worker = () => api("/functions/v1/dispatch-webhooks", workerToken, {});
const inspect = async (h) => {
  const r = await api(
    `/functions/v1/${receiverSlug}/inspect`,
    anon,
    { subscription: h.id },
    "POST",
    anon,
    { "X-Taskfold-Acceptance": controlToken },
  );
  assert.equal(r.status, 200, "Private receiver observation failed");
  assert(Array.isArray(r.value));
  return r.value;
};
const receiverURL = (route) =>
  origin + `/functions/v1/${receiverSlug}/` + route;
async function signin(user) {
  const r = await api("/auth/v1/token?grant_type=password", anon, {
    email: user.email,
    password: user.password,
  });
  assert.equal(r.status, 200, "Synthetic password sign-in failed");
  assert(r.value?.access_token);
  user.token = r.value.access_token;
  user.sid =
    JSON.parse(Buffer.from(user.token.split(".")[1], "base64url")).session_id;
  return user;
}
async function makeUser() {
  const user = {
    email: "taskfold-webhook-" + randomUUID() + "@example.invalid",
    password: randomBytes(32).toString("base64url"),
  };
  const r = await api(
    "/auth/v1/admin/users",
    service,
    { ...user, email_confirm: true },
    "POST",
    service,
  );
  assert.equal(r.status, 200, "Synthetic user creation failed");
  assert(r.value?.id);
  user.id = r.value.id;
  users.push(user);
  await signin(user);
  return user;
}
async function keyFor(user) {
  const id = randomUUID(),
    token = "tfk_v1_" + id.replaceAll("-", "") + "_" +
      randomBytes(32).toString("base64url");
  const r = await api(
    "/functions/v1/automation-keys",
    user.token,
    {
      action: "create",
      body: {
        id,
        name: "Synthetic webhook tool",
        token_hash: createHash("sha256").update(token).digest("hex"),
        ttl_days: 7,
        scopes: [
          "tasks:read",
          "tasks:create",
          "tasks:update",
          "tasks:complete",
          "tasks:delete",
        ],
      },
    },
    "POST",
    anon,
    { "X-Taskfold-Automation": "1" },
  );
  assert.equal(r.status, 200, "Scoped key creation failed");
  return token;
}
async function hook(
  user,
  route = "receive",
  scope = "inbox",
  projectID = null,
  wrong = false,
) {
  const body = {
    id: randomUUID(),
    name: "Synthetic webhook receiver",
    endpoint: receiverURL(route),
    scope,
    project_id: projectID,
    events: [
      "task.created",
      "task.updated",
      "task.completed",
      "task.reopened",
      "task.deleted",
    ],
    ttl_days: 30,
    secret: "tfwh_v1_" +
      (wrong ? randomBytes(32) : secret).toString("base64url"),
  };
  let r = await native(user, "create", body);
  assert.equal(r.status, 200, "Webhook setup failed");
  check(
    "setup-pending-" + body.id,
    r.value?.subscription?.state === "pending" &&
      !JSON.stringify(r.value).includes(body.secret),
  );
  r = await native(user, "verify", { id: body.id, attempt_id: randomUUID() });
  assert.equal(r.status, 200, "Verification request failed");
  check(
    "receiver-proof-" + body.id,
    r.value.subscription.state === (wrong ? "pending" : "active"),
  );
  return r.value.subscription;
}
async function control(user, h, action) {
  const body = {
    id: h.id,
    ...(["pause", "resume"].includes(action)
      ? { request_id: randomUUID(), revision: h.revision }
      : {}),
  };
  const r = await native(user, action, body);
  assert.equal(r.status, 200, "State control failed");
  return { h: r.value.subscription, body };
}
async function createTask(key, fields) {
  const body = {
    id: randomUUID(),
    task_generation: randomUUID(),
    request_id: randomUUID(),
    time_zone: "UTC",
    fields,
  };
  const r = await task(key, "create", body);
  assert.equal(r.status, 200, "Task creation failed");
  assert.equal(r.value?.receipt?.task_id, body.id);
  return body;
}
async function readTask(key, id) {
  const r = await task(key, "get", { id });
  assert.equal(r.status, 200, "Task read failed");
  return r.value.task;
}
async function send() {
  const r = await worker();
  assert.equal(r.status, 200, "Dispatcher did not confirm its run");
  return r.value;
}
const payload = (row) => JSON.parse(row.body);
let failure;
try {
  result.phase = "deploy";
  if (scheduled) {
    check(
      "scheduler-installed-inactive",
      (await database(
        "select not active as ok from cron.job where jobname='taskfold-webhook-dispatch'",
      ))[0].ok,
    );
    // Generate inside the database: no token literal in SQL, files or cron logs.
    await database(
      "select vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'taskfold_webhook_worker_token') as id",
    );
    workerToken = (await database(
      "select decrypted_secret as token from vault.decrypted_secrets where name='taskfold_webhook_worker_token'",
    ))[0].token;
    environment.TASKFOLD_WEBHOOK_WORKER_TOKEN = workerToken;
  }
  await mkdir(join(stage, "supabase/functions"), {
    recursive: true,
    mode: 0o700,
  });
  for (
    const name of [
      "automation-webhooks",
      "automation-keys",
      "automation-tasks",
      "_shared",
      "dispatch-webhooks",
    ]
  ) {
    await cp(
      join(repo, "supabase/functions", name),
      join(stage, "supabase/functions", name),
      { recursive: true },
    );
  }
  await mkdir(join(stage, "Scripts/Diagnostics"), { recursive: true });
  await cp(
    join(repo, "Scripts/Diagnostics/webhook-hosted-receiver.ts"),
    join(stage, "Scripts/Diagnostics/webhook-hosted-receiver.ts"),
  );
  await mkdir(join(stage, "supabase/functions", receiverSlug), {
    recursive: true,
  });
  await writeFile(
    join(stage, "supabase/functions", receiverSlug, "index.ts"),
    `import {receiver} from '../../../Scripts/Diagnostics/webhook-hosted-receiver.ts';\nconst raw=Deno.env.get('TASKFOLD_WEBHOOK_ACCEPTANCE_SECRET')??'';let secret=new Uint8Array();try{secret=Uint8Array.from(atob(raw.replace(/-/g,'+').replace(/_/g,'/')+'='),c=>c.charCodeAt(0));}catch{}\nDeno.serve(receiver({url:Deno.env.get('SUPABASE_URL')??'',service:Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')??'',project:Deno.env.get('TASKFOLD_WEBHOOK_ACCEPTANCE_PROJECT')??'',token:Deno.env.get('TASKFOLD_WEBHOOK_ACCEPTANCE_TOKEN')??'',secret}));\n`,
    { mode: 0o600 },
  );
  await writeFile(
    join(stage, "supabase/config.toml"),
    'project_id="taskfold-webhook-delivery"\n',
    { mode: 0o600 },
  );
  const env = join(stage, "private.env");
  await writeFile(
    env,
    Object.entries(environment).map(([k, v]) => k + "=" + v).join("\n") + "\n",
    { mode: 0o600 },
  );
  await cli(["secrets", "set", "--env-file", env, "--project-ref", project]);
  for (
    const slug of [
      "automation-keys",
      "automation-tasks",
      "automation-webhooks",
      "dispatch-webhooks",
      receiverSlug,
    ]
  ) {
    deployed.push(slug);
    await cli([
      "functions",
      "deploy",
      slug,
      "--project-ref",
      project,
      "--use-api",
      "--workdir",
      stage,
      ...(["automation-tasks", "dispatch-webhooks", receiverSlug].includes(slug)
        ? ["--no-verify-jwt"]
        : []),
    ]);
  }
  check(
    "unsigned-worker-rejected",
    (await api("/functions/v1/dispatch-webhooks", anon, {})).status === 401,
  );
  check(
    "unsigned-receiver-rejected",
    (await api(`/functions/v1/${receiverSlug}/receive`, anon, {})).status ===
      401,
  );
  check(
    "private-inspection-rejected",
    (await api(`/functions/v1/${receiverSlug}/inspect`, anon, {
      subscription: randomUUID(),
    })).status === 401,
  );
  result.phase = "auth";
  const a = await makeUser(), b = await makeUser();
  check("two-real-auth-sessions", a.id !== b.id && a.sid && b.sid);
  const ka = await keyFor(a), kb = await keyFor(b);
  check(
    "native-role-cannot-call-worker",
    (await api("/rest/v1/rpc/taskfold_webhook_dispatch", a.token, {
      _action: "claim",
      _body: {},
    })).status >= 400,
  );
  result.phase = "capture";
  let h = await hook(a);
  check(
    "other-account-list-empty",
    (await native(b, "list")).value.subscriptions.length === 0,
  );
  check(
    "other-account-cannot-revoke",
    (await native(b, "revoke", { id: h.id })).status === 404,
  );
  const paused = await control(a, h, "pause");
  h = paused.h;
  const created = await createTask(ka, {
    title: "Hosted task-change proof",
    description: "Résumé 📝 complete note",
    subtasks: [{ id: randomUUID(), title: "Nested proof", completed: false }],
  });
  check(
    "exact-task-create-replay",
    (await task(ka, "create", created)).status === 200,
  );
  check(
    "paused-queue-sends-nothing",
    (await send()).claimed === 0 && (await inspect(h)).length === 0,
  );
  const resumed = await control(a, h, "resume");
  h = resumed.h;
  const late = await native(a, "pause", paused.body);
  check(
    "old-pause-retry-cannot-override-resume",
    late.status === 200 && late.value.subscription.state === "active" &&
      late.value.subscription.revision === h.revision,
  );
  check("one-committed-create-delivered", (await send()).delivered === 1);
  let received = await inspect(h);
  check(
    "full-create-snapshot-and-no-native-credentials",
    received.length === 1 && received[0].headers_safe &&
      payload(received[0]).task.description === "Résumé 📝 complete note" &&
      payload(received[0]).task.subtasks.length === 1,
  );
  for (const action of ["update", "complete", "reopen"]) {
    const base = await readTask(ka, created.id),
      body = {
        id: created.id,
        task_generation: created.task_generation,
        request_id: randomUUID(),
        time_zone: "UTC",
        base,
        ...(action === "update"
          ? { fields: { title: "Edited hosted proof" } }
          : {}),
      };
    check("real-task-" + action, (await task(ka, action, body)).status === 200);
    await send();
  }
  const base = await readTask(ka, created.id);
  check(
    "reviewed-task-delete",
    (await task(ka, "delete", {
      id: created.id,
      task_generation: created.task_generation,
      request_id: randomUUID(),
      time_zone: "UTC",
      revision: base.revision,
      descendants: [],
    })).status === 200,
  );
  await send();
  received = await inspect(h);
  for (
    const type of [
      "task.created",
      "task.updated",
      "task.completed",
      "task.reopened",
      "task.deleted",
    ]
  ) {
    check(
      "actual-event-" + type,
      received.some((r) => payload(r).type === type),
    );
  }
  const deletion = received.map(payload).find((v) => v.type === "task.deleted");
  check(
    "minimal-delete-hides-task-content",
    Object.keys(deletion.task).sort().join(",") ===
        "id,project_id,task_generation" &&
      deletion.task.task_generation === created.task_generation,
  );
  result.phase = "multipart";
  const note = "Résumé 📝\n".repeat(30000);
  await createTask(ka, {
    title: "Large Unicode webhook proof",
    description: note,
  });
  const sent = await send();
  received = await inspect(h);
  const frames = received.map(payload).filter((v) =>
    v.type === "taskfold.event.part"
  ).sort((a, b) => a.part_index - b.part_index);
  check(
    "large-task-delivers-multiple-signed-parts",
    frames.length >= 2 && sent.delivered === frames.length &&
      frames.every((v, i) =>
        v.part_index === i && v.part_count === frames.length
      ),
  );
  const bytes = Buffer.concat(frames.map((v) => Buffer.from(v.data, "base64")));
  check(
    "complete-multipart-checksum",
    frames.every((v) =>
      v.sha256 === createHash("sha256").update(bytes).digest("hex")
    ),
  );
  check(
    "complete-unicode-note-roundtrip",
    JSON.parse(bytes.toString("utf8")).task.description === note,
  );
  h = (await control(a, h, "revoke")).h;
  await send();
  result.phase = "retry";
  let retry = await hook(a, "retry");
  await createTask(ka, { title: "Automatic retry proof" });
  check("temporary-receiver-is-retried", (await send()).retrying === 1);
  let history = await native(a, "history", { id: retry.id });
  assert.equal(history.status, 200);
  const first = history.value.events[0];
  check(
    "retry-is-pending-with-backoff",
    first.status === "pending" &&
      Date.parse(first.next_attempt_at) > Date.now() + 20000,
  );
  check(
    "real-signout",
    (await api("/auth/v1/logout", a.token, {})).status === 204,
  );
  check("old-session-cannot-manage", (await native(a, "list")).status === 401);
  while (Date.now() < Date.parse(first.next_attempt_at) + 500) {
    await new Promise((r) => setTimeout(r, 1000));
  }
  check(
    "connected-hook-survives-native-signout",
    (await send()).delivered === 1,
  );
  received = await inspect(retry);
  check(
    "retry-keeps-exact-body-and-message-id",
    received.length === 1 && received[0].attempts === 2 &&
      payload(received[0]).event_id === first.id,
  );
  await signin(a);
  retry = (await control(a, retry, "revoke")).h;
  await send();
  result.phase = "manual-recovery";
  let refused = await hook(a, "refuse");
  await createTask(ka, { title: "Reviewed retry proof" });
  check("refused-receiver-fails", (await send()).failed === 1);
  history = await native(a, "history", { id: refused.id });
  refused = history.value.subscription;
  const failed = history.value.events[0];
  check(
    "refusal-is-visible-and-body-not-exposed",
    refused.delivery.blocked_reason === "refused" &&
      failed.status === "failed" &&
      !JSON.stringify(history.value).includes("Reviewed retry proof"),
  );
  const intent = {
    id: refused.id,
    event_id: failed.id,
    request_id: randomUUID(),
  };
  check(
    "blocked-retry-requires-resume",
    (await native(a, "retry_delivery", intent)).status === 409,
  );
  const resume = await control(a, refused, "resume");
  refused = resume.h;
  check(
    "manual-retry-queued",
    (await native(a, "retry_delivery", intent)).status === 200,
  );
  check("manual-retry-reaches-receiver", (await send()).failed === 1);
  check(
    "late-manual-retry-does-not-requeue",
    (await native(a, "retry_delivery", intent)).status === 200 &&
      (await send()).claimed === 0,
  );
  const oldResume = await native(a, "resume", resume.body);
  check(
    "late-resume-does-not-clear-new-refusal",
    oldResume.status === 200 &&
      oldResume.value.subscription.delivery.blocked_reason === "refused" &&
      (await send()).claimed === 0,
  );
  received = await inspect(refused);
  check(
    "manual-retry-keeps-immutable-message",
    received.length === 1 && received[0].attempts === 2,
  );
  await control(a, refused, "revoke");
  await send();
  result.phase = "receiver-proof";
  const unverified = await hook(a, "receive", "inbox", null, true);
  await createTask(ka, { title: "Unverified receiver must see nothing" });
  check(
    "wrong-secret-peer-never-gets-task-data",
    (await send()).claimed === 0 && (await inspect(unverified)).length === 0,
  );
  await control(a, unverified, "revoke");
  result.phase = "shared-project-access";
  const projectID = randomUUID(), membership = randomUUID();
  const projectCreated = await api("/rest/v1/projects", b.token, {
    id: projectID,
    user_id: b.id,
    name: "Hosted shared-project proof",
  });
  assert.equal(projectCreated.status, 201, "Synthetic project creation failed");
  const invited = await api(
    "/rest/v1/project_collaborators",
    service,
    {
      id: membership,
      project_id: projectID,
      user_id: a.id,
      invited_by: b.id,
      invited_email: a.email,
      role: "collaborator",
      status: "pending",
    },
    "POST",
    service,
  );
  assert.equal(invited.status, 201, "Synthetic invitation failed");
  const pendingSetup = {
    id: randomUUID(),
    name: "Shared project receiver",
    endpoint: receiverURL("receive"),
    scope: "project",
    project_id: projectID,
    events: ["task.created", "task.updated"],
    ttl_days: 30,
    secret: "tfwh_v1_" + secret.toString("base64url"),
  };
  check(
    "pending-invite-does-not-authorize-subscription",
    (await native(a, "create", pendingSetup)).status === 404,
  );
  const accepted = await api(
    "/rest/v1/project_collaborators?id=eq." + membership,
    service,
    { status: "accepted" },
    "PATCH",
    service,
  );
  assert.equal(accepted.status, 204, "Synthetic acceptance failed");
  const shared = await hook(a, "receive", "project", projectID);
  await createTask(ka, {
    title: "Remove access before sending",
    project_id: projectID,
  });
  check(
    "owner-removes-membership",
    (await api(
      "/rest/v1/project_collaborators?id=eq." + membership,
      b.token,
      undefined,
      "DELETE",
    )).status === 204,
  );
  await send();
  check(
    "removed-member-receives-no-task-content",
    (await inspect(shared)).length === 0,
  );
  const cancelled = await native(a, "history", { id: shared.id });
  check(
    "lost-access-event-cancelled",
    cancelled.status === 200 && cancelled.value.events.length === 1 &&
      cancelled.value.events[0].status === "cancelled",
  );
  const ownerHook = await hook(b, "receive", "project", projectID);
  await createTask(kb, {
    title: "Project owner retains access",
    project_id: projectID,
  });
  check(
    "real-project-owner-still-receives",
    (await send()).delivered === 1 && (await inspect(ownerHook)).length === 1,
  );
  if (scheduled) {
    result.phase = "scheduled-delivery";
    const schedulerHook = await hook(a);
    check(
      "native-cannot-invoke-scheduler",
      (await database(
        "select not has_function_privilege('authenticated','taskfold_private.invoke_webhook_worker()','execute') as ok",
      ))[0].ok,
    );
    await database(
      `select taskfold_private.configure_webhook_scheduler('${project}',true)`,
    );
    await createTask(ka, { title: "Actual cron delivery proof" });
    const limit = Date.now() + 95000;
    let messages = [];
    while (Date.now() < limit) {
      messages = await inspect(schedulerHook);
      if (messages.length) break;
      await new Promise((r) => setTimeout(r, 2000));
    }
    check("real-cron-delivers-without-manual-worker", messages.length === 1);
    check(
      "scheduled-event-is-exact-task",
      payload(messages[0]).task.title === "Actual cron delivery proof",
    );
    const responseLimit = Date.now() + 15000;
    while (Date.now() < responseLimit) {
      const ready = (await database(
        "select exists(select 1 from net._http_response r join taskfold_private.webhook_scheduler s on s.last_request_id=r.id) as ok",
      ))[0].ok;
      if (ready) break;
      await new Promise((r) => setTimeout(r, 1000));
    }
    check(
      "signed-tick-admitted-only-once",
      (await database(
        "select consumed_at is not null and not taskfold_private.admit_webhook_schedule(scheduled_nonce,scheduled_issued) as ok from taskfold_private.webhook_scheduler",
      ))[0].ok,
    );
    check(
      "native-api-cannot-read-transient-queue",
      (await api(
        "/rest/v1/http_request_queue?select=id",
        a.token,
        undefined,
        "GET",
        anon,
        { "Accept-Profile": "net" },
      )).status === 406,
    );
    await database(
      "select taskfold_private.invoke_webhook_worker() is null as throttled",
    );
    const health = (await database(
      "select last_request_id is not null as queued,last_response_code,last_response_timed_out from taskfold_private.webhook_scheduler",
    ))[0];
    check(
      "scheduled-http-success-visible",
      health.queued && health.last_response_code === 200 &&
        health.last_response_timed_out === false,
    );
    check(
      "actual-cron-run-succeeded",
      (await database(
        "select exists(select 1 from cron.job_run_details r join cron.job j using(jobid) where j.jobname='taskfold-webhook-dispatch' and r.status='succeeded') as ok",
      ))[0].ok,
    );
    await database(
      "select taskfold_private.configure_webhook_scheduler(null,false)",
    );
    await createTask(ka, { title: "Disabled cron must not deliver" });
    const nextTick = Math.floor(Date.now() / 60000) * 60000 + 65000;
    while (Date.now() < nextTick) {
      await new Promise((r) =>
        setTimeout(r, Math.min(2000, nextTick - Date.now()))
      );
    }
    check(
      "disabled-cron-does-not-deliver-next-tick",
      (await inspect(schedulerHook)).length === 1,
    );
    check(
      "scheduler-off-after-test",
      (await database(
        "select not active as ok from cron.job where jobname='taskfold-webhook-dispatch'",
      ))[0].ok,
    );
    await control(a, schedulerHook, "revoke");
    result.scheduledInvocationClaimed = true;
  }
  result.phase = "removal";
  let removal = await hook(b);
  await createTask(kb, { title: "Removal must cancel before delivery" });
  const removalResponse = await api(
    "/rest/v1/rpc/taskfold_account_removal_begin",
    service,
    {
      _account: b.id,
      _session: b.sid,
      _token_hash: randomBytes(32).toString("hex"),
    },
    "POST",
    service,
  );
  assert.equal(
    removalResponse.status,
    200,
    "Synthetic removal preparation failed",
  );
  await send();
  check(
    "account-removal-blocks-unsent-content",
    (await inspect(removal)).length === 0,
  );
  check(
    "removing-account-cannot-manage",
    (await native(b, "list")).status === 401,
  );
  result.phase = "passed";
  result.passed = true;
} catch (error) {
  failure = error;
  result.passed = false;
  result.failure = { phase: result.phase, message: error.message };
} finally {
  if (scheduled) {
    try {
      await database(
        "select taskfold_private.configure_webhook_scheduler(null,false)",
      );
      await database(
        "delete from vault.secrets where name='taskfold_webhook_worker_token' returning id",
      );
      result.cleanup.scheduler = true;
    } catch {
      result.cleanup.scheduler = false;
      result.cleanupError = "Scheduler cleanup failed";
    }
  }
  for (const user of users) {
    try {
      const r = await api(
        "/auth/v1/admin/users/" + user.id,
        service,
        undefined,
        "DELETE",
        service,
      );
      assert([200, 204, 404].includes(r.status));
    } catch {
      result.cleanupError = "Synthetic user cleanup failed";
    }
  }
  result.cleanup.users = !result.cleanupError;
  try {
    for (const slug of deployed) {
      await cli([
        "functions",
        "delete",
        slug,
        "--project-ref",
        project,
        "--yes",
      ]);
    }
    result.cleanup.functions = true;
  } catch {
    result.cleanupError = "Owned function cleanup failed";
  }
  try {
    await cli([
      "secrets",
      "unset",
      ...Object.keys(environment),
      "--project-ref",
      project,
      "--yes",
    ]);
    result.cleanup.secrets = true;
  } catch {
    result.cleanupError = "Owned secret cleanup failed";
  }
  await rm(stage, { recursive: true, force: true });
  result.cleanup.files = true;
  await writeFile(output, JSON.stringify(result, null, 2) + "\n");
  console.log(
    JSON.stringify({
      passed: result.passed,
      phase: result.phase,
      checks: Object.keys(result.checks).length,
      cleanup: result.cleanup,
      failure: result.failure,
    }),
  );
}
if (failure || result.cleanupError) process.exitCode = 1;
