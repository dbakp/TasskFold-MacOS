// Real Auth -> Edge -> PostgREST acceptance. Only a data-excluding preview branch.
// Credentials are read from an owner-private CLI export, never arguments or output.
import assert from "node:assert/strict";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const [connectionPath, output] = process.argv.slice(2);
if (!connectionPath || !output) {
  throw Error("Supply private connection JSON and summary paths");
}
const parent = "zqxflydiyfjeedqvyova";
const exec = promisify(execFile);
const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const receipt = {
  date: new Date().toISOString(),
  checks: {},
  realTasksChanged: 0,
  productionEnabled: false,
  cleanup: { users: false, functions: false, files: false },
};
const check = (name, value) => {
  receipt.checks[name] = !!value;
  assert(value, name);
};
async function cli(args) {
  try {
    return (await exec("supabase", args, {
      timeout: 90000,
      maxBuffer: 1024 * 1024,
    })).stdout;
  } catch {
    throw Error("Owned branch CLI action failed");
  }
}
const config = JSON.parse(await readFile(connectionPath, "utf8"));
assert(
  ((await stat(connectionPath)).mode & 0o077) === 0,
  "Connection file must be owner-private",
);
const origin = new URL(config.SUPABASE_URL).origin;
const project = new URL(origin).hostname.split(".")[0];
assert(
  project !== parent && /^[a-z]{20}$/.test(project),
  "Refuse primary project",
);
const branches = JSON.parse(
  await cli(["branches", "list", "--project-ref", parent, "--output", "json"]),
);
const branch = branches.find((b) => b.project_ref === project);
assert(
  branch && !branch.is_default && branch.with_data === false &&
    !branch.persistent &&
    branch.name.startsWith("codex-automation-acceptance-"),
  "Refuse unowned or data-bearing branch",
);
receipt.project = project;
receipt.branchId = branch.id;
const anon = config.SUPABASE_ANON_KEY,
  service = config.SUPABASE_SERVICE_ROLE_KEY;
assert(anon && service, "Missing private credentials");
const suffix = randomUUID().replaceAll("-", "").slice(0, 12);
const keysSlug = "taskfold-accept-keys-" + suffix,
  tasksSlug = "taskfold-accept-tasks-" + suffix;
const users = [], deployed = [];
const stage = await mkdtemp(join(tmpdir(), "taskfold-hosted-"));
let failed;
async function request(
  path,
  token,
  body,
  method = "POST",
  apiKey = anon,
  extra = {},
) {
  const response = await fetch(origin + path, {
    method,
    redirect: "error",
    signal: AbortSignal.timeout(25000),
    headers: {
      apikey: apiKey,
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
      ...extra,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  if (text.length > 1048576) throw Error("Hosted reply exceeded fixture bound");
  let value = null;
  try {
    value = text ? JSON.parse(text) : null;
  } catch { /* Sanitized diagnostic only. */ }
  receipt.lastHTTPStatus = response.status;
  return {
    status: response.status,
    value,
    cache: response.headers.get("Cache-Control"),
  };
}
const manage = (token, action, body) =>
  request("/functions/v1/" + keysSlug, token, { action, body }, "POST", anon, {
    "X-Taskfold-Automation": "1",
  });
const task = (token, action, body) =>
  request(
    "/functions/v1/" + tasksSlug +
      (["create", "update", "complete", "reopen", "delete"].includes(action)
        ? "/write"
        : ""),
    token,
    { action, body },
    "POST",
    anon,
    {
      "X-Taskfold-Automation": "1",
    },
  );
let signIns = 0;
async function signIn(email, password) {
  const result = await request("/auth/v1/token?grant_type=password", anon, {
    email,
    password,
  });
  check(
    "real-password-session-" + (++signIns),
    result.status === 200 && !!result.value?.access_token,
  );
  return result.value.access_token;
}
function credential(scopes) {
  const id = randomUUID(),
    secret = "tfk_v1_" + id.replaceAll("-", "") + "_" +
      randomBytes(32).toString("base64url");
  return {
    id,
    secret,
    body: {
      id,
      name: "Hosted synthetic acceptance",
      token_hash: createHash("sha256").update(secret).digest("hex"),
      ttl_days: 7,
      scopes,
    },
  };
}
try {
  receipt.phase = "deploy";
  for (
    const path of [
      "supabase/functions/automation-keys/handler.ts",
      "supabase/functions/automation-tasks/handler.ts",
      "supabase/functions/_shared/automation-admission.ts",
    ]
  ) {
    await mkdir(dirname(join(stage, path)), { recursive: true, mode: 0o700 });
    await copyFile(join(repo, path), join(stage, path));
  }
  await writeFile(
    join(stage, "supabase/config.toml"),
    'project_id = "taskfold-hosted-acceptance"\n',
    { mode: 0o600 },
  );
  for (const [slug, kind] of [[keysSlug, "keys"], [tasksSlug, "tasks"]]) {
    await mkdir(join(stage, "supabase/functions", slug), {
      recursive: true,
      mode: 0o700,
    });
    await writeFile(
      join(stage, "supabase/functions", slug, "index.ts"),
      `import {createHandler} from '../automation-${kind}/handler.ts';\nDeno.serve(createHandler({url:Deno.env.get('SUPABASE_URL')??'',serviceKey:Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')??'',forwardedForMode:'supabase-cloudflare-v1'}));\n`,
      { mode: 0o600 },
    );
    deployed.push(slug); // Cleanup even if the deployment reply is lost.
    await cli([
      "functions",
      "deploy",
      slug,
      "--project-ref",
      project,
      "--use-api",
      "--workdir",
      stage,
      ...(kind === "tasks" ? ["--no-verify-jwt"] : []),
    ]);
  }
  receipt.phase = "auth";
  const sessions = [];
  for (let index = 0; index < 2; index++) {
    const email = `taskfold-accept-${suffix}-${index}@example.invalid`,
      password = randomBytes(32).toString("base64url");
    const made = await request(
      "/auth/v1/admin/users",
      service,
      {
        email,
        password,
        email_confirm: true,
        user_metadata: { display_name: "Synthetic acceptance" },
      },
      "POST",
      service,
    );
    check(
      "synthetic-user-" + index,
      made.status === 200 && /^[a-f0-9-]{36}$/.test(made.value?.id ?? ""),
    );
    users.push(made.value.id);
    sessions.push({ email, password, token: await signIn(email, password) });
  }
  const a = sessions[0], b = sessions[1];
  receipt.phase = "management";
  check(
    "empty-owner-list",
    (await manage(a.token, "list", {})).value?.keys?.length === 0,
  );
  const key = credential([
    "tasks:read",
    "tasks:create",
    "tasks:update",
    "tasks:complete",
    "tasks:delete",
  ]);
  const made = await manage(a.token, "create", key.body);
  check(
    "verified-native-session-enrolls",
    made.status === 200 && made.value?.key?.id === key.id,
  );
  check(
    "only-public-key-metadata",
    !JSON.stringify(made.value).includes(key.secret) &&
      !JSON.stringify(made.value).includes(key.body.token_hash),
  );
  const retry = await manage(a.token, "create", key.body);
  check(
    "lost-enrollment-reply-retry",
    retry.status === 200 &&
      retry.value?.key?.expires_at === made.value.key.expires_at,
  );
  check(
    "other-account-cannot-revoke",
    (await manage(b.token, "revoke", { id: key.id })).status === 403,
  );
  check(
    "other-account-list-empty",
    (await manage(b.token, "list", {})).value?.keys?.length === 0,
  );
  const discarded = credential(["tasks:read"]);
  check(
    "cancel-before-create",
    (await manage(a.token, "cancel", { id: discarded.id })).value?.cancelled ===
      true,
  );
  check(
    "late-create-permanently-refused",
    (await manage(a.token, "create", discarded.body)).status === 409,
  );
  const readonly = credential(["tasks:read"]);
  check(
    "read-key-enrolls",
    (await manage(a.token, "create", readonly.body)).status === 200,
  );
  receipt.phase = "task-effects";
  const target = randomUUID(), generation = randomUUID();
  const create = {
    id: target,
    task_generation: generation,
    request_id: randomUUID(),
    time_zone: "UTC",
    fields: { title: "Hosted synthetic task" },
  };
  check(
    "read-scope-cannot-create",
    (await task(readonly.secret, "create", create)).status === 403,
  );
  const created = await task(key.secret, "create", create);
  check(
    "hosted-create",
    created.status === 200 && created.value?.receipt?.task_id === target,
  );
  check("hosted-no-store", created.cache === "no-store");
  const replay = await task(key.secret, "create", create);
  check(
    "exact-request-replay",
    replay.status === 200 && replay.value?.replayed === true &&
      JSON.stringify(replay.value.receipt) ===
        JSON.stringify(created.value.receipt),
  );
  let read = await task(key.secret, "get", { id: target });
  check(
    "current-owner-projection",
    read.status === 200 && read.value?.task?.user_id === users[0],
  );
  check(
    "read-key-can-get",
    (await task(readonly.secret, "get", { id: target })).status === 200,
  );
  const foreign = credential(["tasks:read"]);
  check(
    "second-account-key-enrolls",
    (await manage(b.token, "create", foreign.body)).status === 200,
  );
  check(
    "second-account-task-isolation",
    (await task(foreign.secret, "get", { id: target })).status === 404,
  );
  const direct = await request(
    "/rest/v1/rpc/taskfold_automation_keys",
    a.token,
    { _account: users[0], _session: randomUUID(), _action: "list", _body: {} },
  );
  check(
    "native-cannot-bypass-service-wrapper",
    direct.status === 401 || direct.status === 403,
  );
  const firstPage = await manage(a.token, "list", { limit: 1 });
  check(
    "hosted-key-page-cursor",
    firstPage.status === 200 && firstPage.value?.keys?.length === 1 &&
      !!firstPage.value?.next_cursor,
  );
  const secondPage = await manage(a.token, "list", {
    limit: 1,
    cursor: firstPage.value.next_cursor,
  });
  check(
    "hosted-key-second-page",
    secondPage.status === 200 && secondPage.value?.keys?.length === 1 &&
      secondPage.value?.keys[0].id !== firstPage.value.keys[0].id &&
      secondPage.value.next_cursor === null,
  );
  check(
    "real-destination-discovery",
    (await task(key.secret, "projects", {})).value?.inbox?.name === "Inbox",
  );
  const updated = await task(key.secret, "update", {
    id: target,
    task_generation: generation,
    request_id: randomUUID(),
    time_zone: "UTC",
    base: read.value.task,
    fields: { title: "Edited hosted synthetic task" },
  });
  check("hosted-update", updated.status === 200);
  read = await task(key.secret, "get", { id: target });
  check(
    "edit-persisted",
    read.value?.task?.title === "Edited hosted synthetic task",
  );
  check(
    "hosted-complete",
    (await task(key.secret, "complete", {
      id: target,
      task_generation: generation,
      request_id: randomUUID(),
      time_zone: "UTC",
      base: read.value.task,
    })).status === 200,
  );
  read = await task(key.secret, "get", { id: target });
  check("completion-persisted", read.value?.task?.completed === true);
  check(
    "hosted-reopen",
    (await task(key.secret, "reopen", {
      id: target,
      task_generation: generation,
      request_id: randomUUID(),
      time_zone: "UTC",
      base: read.value.task,
    })).status === 200,
  );
  check(
    "reopen-persisted",
    (await task(key.secret, "get", { id: target })).value?.task?.completed ===
      false,
  );
  check(
    "cancel-existing-key",
    (await manage(a.token, "cancel", { id: readonly.id })).value?.cancelled ===
      true,
  );
  check(
    "cancelled-existing-key-refused",
    (await task(readonly.secret, "get", { id: target })).status === 401,
  );
  receipt.phase = "session-revocation";
  check(
    "real-signout",
    (await request("/auth/v1/logout?scope=global", a.token, undefined))
      .status === 204,
  );
  check(
    "old-native-session-management-refused",
    (await manage(a.token, "list", {})).status === 401,
  );
  check(
    "delegated-key-survives-native-signout",
    (await task(key.secret, "get", { id: target })).status === 200,
  );
  a.token = await signIn(a.email, a.password);
  check(
    "new-native-session-lists-key",
    (await manage(a.token, "list", {})).value?.keys?.some((x) =>
      x.id === key.id
    ),
  );
  read = await task(key.secret, "get", { id: target });
  check(
    "reviewed-hosted-delete",
    (await task(key.secret, "delete", {
      id: target,
      task_generation: generation,
      request_id: randomUUID(),
      time_zone: "UTC",
      revision: read.value.task.revision,
      descendants: [],
    })).value?.receipt?.deleted === true,
  );
  check(
    "deleted-task-unavailable",
    (await task(key.secret, "get", { id: target })).status === 404,
  );
  check(
    "owner-revokes-key",
    (await manage(a.token, "revoke", { id: key.id })).status === 200,
  );
  check(
    "revoked-key-cannot-replay",
    (await task(key.secret, "create", create)).status === 401,
  );
  receipt.phase = "passed";
} catch (error) {
  failed = error;
  receipt.failureHTTPStatus = receipt.lastHTTPStatus;
  receipt.failure = error instanceof assert.AssertionError
    ? error.message
    : "Hosted fixture failed at " + receipt.phase;
} finally {
  const cleanUsers = await Promise.all(users.map(async (id) => {
    try {
      const r = await request(
        "/auth/v1/admin/users/" + id,
        service,
        undefined,
        "DELETE",
        service,
      );
      return r.status === 200;
    } catch {
      return false;
    }
  }));
  receipt.cleanup.users = cleanUsers.every(Boolean);
  const cleanFunctions = await Promise.all(deployed.map(async (slug) => {
    try {
      await cli([
        "functions",
        "delete",
        slug,
        "--project-ref",
        project,
        "--yes",
      ]);
      return true;
    } catch {
      return false;
    }
  }));
  receipt.cleanup.functions = cleanFunctions.every(Boolean);
  await rm(stage, { recursive: true, force: true });
  receipt.cleanup.files = true;
  receipt.assertions = Object.values(receipt.checks).filter(Boolean).length;
  receipt.passed = !failed && Object.values(receipt.cleanup).every(Boolean);
  await writeFile(output, JSON.stringify(receipt, null, 2) + "\n", {
    mode: 0o600,
  });
  console.log(
    JSON.stringify({
      passed: receipt.passed,
      assertions: receipt.assertions,
      phase: receipt.phase,
      cleanup: receipt.cleanup,
    }),
  );
}
if (!receipt.passed) process.exitCode = 1;
