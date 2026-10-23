// Genuine Auth -> hosted email gateway -> PostgREST -> SQL. No inbound provider,
// copied user data, fake token, or source replacement. Owned no-data branch only.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  cp,
  mkdtemp,
  readdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const [connectionPath, schemaPath, output] = process.argv.slice(2);
assert(
  connectionPath && schemaPath && output,
  "Supply private preview connection, schema receipt and safe output paths",
);
const exec = promisify(execFile),
  repo = resolve(dirname(fileURLToPath(import.meta.url)), "../.."),
  parent = "zqxflydiyfjeedqvyova";
assert(
  ((await stat(connectionPath)).mode & 0o077) === 0,
  "Private connection required",
);
const config = JSON.parse(await readFile(connectionPath, "utf8")),
  origin = config.SUPABASE_URL,
  project = new URL(origin).hostname.split(".")[0];
assert(
  /^[a-z]{20}$/.test(project) && project !== parent &&
    origin === `https://${project}.supabase.co`,
  "Refuse primary/unrelated host",
);
async function cli(args) {
  try {
    return (await exec("supabase", args, {
      timeout: 90000,
      maxBuffer: 1048576,
    })).stdout;
  } catch {
    throw Error("Owned email preview CLI action failed");
  }
}
const branch = JSON.parse(
  await cli(["branches", "list", "--project-ref", parent, "--output", "json"]),
).find((b) => b.project_ref === project);
assert(
  branch && !branch.is_default && !branch.persistent &&
    branch.with_data === false &&
    branch.name.startsWith("codex-webhook-delivery-acceptance-email-"),
  "Refuse unowned or data-bearing branch",
);
const schema = JSON.parse(await readFile(schemaPath, "utf8"));
assert(schema.project === project && schema.branchId === branch.id);
const result = {
  date: new Date().toISOString(),
  project,
  branchId: branch.id,
  checks: {},
  sourceHashes: {},
  mainChanged: false,
  realTasksChanged: 0,
  providerDeliveryClaimed: false,
  nativeUIClaimed: false,
  cleanup: {
    users: false,
    function: false,
    environment: false,
    files: false,
    configuration: false,
  },
};
for (
  const folder of [
    "supabase/functions/email-routes",
    "supabase/functions/_shared",
  ]
) {
  for (
    const entry of await readdir(join(repo, folder), { withFileTypes: true })
  ) {
    if (entry.isFile()) {
      const path = folder + "/" + entry.name;
      result.sourceHashes[path] = createHash("sha256").update(
        await readFile(join(repo, path)),
      ).digest("hex");
    }
  }
}
for (
  const file of [
    "20261023150729_email_intake_journal.sql",
    "20261023162006_email_domain_binding.sql",
    "20261023182542_email_inactive_maintenance.sql",
  ]
) {
  const path = "supabase/migrations/" + file,
    hash = createHash("sha256").update(await readFile(join(repo, path))).digest(
      "hex",
    );
  assert(
    schema.migrationHashes[file] === hash,
    "Email schema source differs from prepared branch",
  );
  result.sourceHashes[path] = hash;
}
result.sourceHashes["Scripts/Diagnostics/test-email-routes-hosted.mjs"] =
  createHash("sha256").update(await readFile(fileURLToPath(import.meta.url)))
    .digest("hex");
const stage = await mkdtemp(join(tmpdir(), "taskfold-email-routes-")),
  users = [],
  domain = "mail.example.invalid";
const environment = {
  TASKFOLD_AUTOMATION_FORWARDED_FOR_MODE: "supabase-cloudflare-v1",
  TASKFOLD_EMAIL_INBOUND_DOMAIN: domain,
};
let deployed = false, environmentSet = false;
const lit = (v) => "'" + String(v).replaceAll("'", "''") + "'";
const check = (name, value) => {
  result.checks[name] = !!value;
  assert(value, name);
};
async function database(sql) {
  const url = new URL(config.POSTGRES_URL);
  assert(
    ["postgres:", "postgresql:"].includes(url.protocol) &&
      ((url.hostname === `db.${project}.supabase.co` &&
        url.username === "postgres") ||
        (/^aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com$/.test(url.hostname) &&
          decodeURIComponent(url.username) === `postgres.${project}`)),
    "Database must match owned preview",
  );
  const path = join(stage, "query.sql");
  await writeFile(path, sql, { mode: 0o600 });
  return JSON.parse(
    await cli([
      "db",
      "query",
      "--db-url",
      config.POSTGRES_URL,
      "--file",
      path,
      "--output",
      "json",
    ]),
  ).rows;
}
async function api(
  path,
  token,
  body,
  method = "POST",
  key = config.SUPABASE_ANON_KEY,
  extra = {},
) {
  const r = await fetch(origin + path, {
    method,
    redirect: "error",
    signal: AbortSignal.timeout(25000),
    headers: {
      apikey: key,
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
      ...extra,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const reader = r.body?.getReader(), parts = [];
  let length = 0;
  if (reader) {
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        length += value.length;
        assert(length <= 1024 * 1024, "Oversize hosted response");
        parts.push(value);
      }
    } finally {
      await reader.cancel();
    }
  }
  const text = Buffer.concat(parts).toString("utf8");
  let value;
  try {
    value = text ? JSON.parse(text) : null;
  } catch {
    value = null;
  }
  return {
    status: r.status,
    value,
    text,
    cache: r.headers.get("cache-control"),
  };
}
const native = (user, action, body = {}, extra = {}) =>
  api(
    "/functions/v1/email-routes",
    user.token,
    { action, body },
    "POST",
    config.SUPABASE_ANON_KEY,
    { "X-Taskfold-Email": "2", "X-Taskfold-Email-Domain": domain, ...extra },
  );
async function signin(user, password = user.password) {
  const r = await api(
    "/auth/v1/token?grant_type=password",
    config.SUPABASE_ANON_KEY,
    { email: user.email, password },
  );
  if (r.status === 200) {
    assert(r.value.access_token);
    user.token = r.value.access_token;
    user.session =
      JSON.parse(Buffer.from(user.token.split(".")[1], "base64url")).session_id;
  }
  return r;
}
async function makeUser() {
  const user = {
    email: "taskfold-email-" + randomUUID() + "@example.invalid",
    password: randomBytes(32).toString("base64url"),
  };
  const r = await api(
    "/auth/v1/admin/users",
    config.SUPABASE_SERVICE_ROLE_KEY,
    { ...user, email_confirm: true },
    "POST",
    config.SUPABASE_SERVICE_ROLE_KEY,
  );
  assert.equal(r.status, 200, "Create synthetic account");
  assert(r.value.id);
  user.id = r.value.id;
  users.push(user);
  assert.equal((await signin(user)).status, 200, "Actual password Auth");
  return user;
}
const draft = () => ({
  id: randomUUID(),
  name: "Hosted email recovery proof",
  alias_hash: randomBytes(32).toString("hex"),
  domain,
  project_id: null,
  requested_at: new Date().toISOString(),
});
const snapshot = async (id) =>
  (await database(
    `select to_jsonb(r) as value from taskfold_private.email_routes r where id=${
      lit(id)
    }`,
  ))[0]?.value;
const tasks = async () =>
  (await database(
    "select coalesce(jsonb_agg(to_jsonb(t)order by id),'[]'::jsonb)as value from public.tasks t",
  ))[0].value;
try {
  result.phase = "deploy";
  await cp(
    join(repo, "supabase/functions/email-routes"),
    join(stage, "supabase/functions/email-routes"),
    { recursive: true },
  );
  await cp(
    join(repo, "supabase/functions/_shared"),
    join(stage, "supabase/functions/_shared"),
    { recursive: true },
  );
  await writeFile(
    join(stage, "supabase/config.toml"),
    'project_id="taskfold-email-hosted"\n[functions.email-routes]\nverify_jwt=true\n',
    { mode: 0o600 },
  );
  const env = join(stage, "email.env");
  await writeFile(
    env,
    Object.entries(environment).map(([k, v]) => k + "=" + v).join("\n") + "\n",
    { mode: 0o600 },
  );
  await cli(["secrets", "set", "--env-file", env, "--project-ref", project]);
  environmentSet = true;
  await cli([
    "functions",
    "deploy",
    "email-routes",
    "--project-ref",
    project,
    "--use-api",
    "--workdir",
    stage,
  ]);
  deployed = true;
  await database(
    `select public.taskfold_email_configure('synthetic-adapter',${
      lit(domain)
    },true)`,
  );
  const a = await makeUser(), b = await makeUser();
  const preservedTask = await api("/rest/v1/tasks", a.token, {
    id: randomUUID(),
    user_id: a.id,
    title: "Keep my original task",
    description: "Synthetic note preserved through email recovery",
    priority: 2,
    completed: false,
    labels: ["synthetic"],
  });
  assert.equal(preservedTask.status, 201, "Create synthetic saved task");
  const initialTasks = await tasks();
  check(
    "nonempty saved task snapshot recorded",
    initialTasks.length === 1 &&
      initialTasks[0].title === "Keep my original task",
  );
  result.phase = "management";
  let r = await native(a, "list");
  check(
    "actual Auth and hosted list succeed",
    r.status === 200 && r.value.protocol === 2 && r.value.account === a.id &&
      r.value.available === true && r.value.domain === domain &&
      r.value.routes.length === 0,
  );
  check("successful metadata is not cached", r.cache === "no-store");
  check(
    "old native protocol refused",
    (await native(a, "list", {}, { "X-Taskfold-Email": "1" })).status === 428,
  );
  check(
    "unknown management field refused",
    (await native(a, "list", { owner: b.id })).status === 400,
  );
  const first = draft();
  check(
    "unreviewed domain refused",
    (await native(a, "create", first, {
      "X-Taskfold-Email-Domain": "other.example.invalid",
    })).status === 409,
  );
  r = await native(a, "create", first);
  check(
    "hosted setup creates owner bound route",
    r.status === 200 && r.value.account === a.id &&
      r.value.route.id === first.id && r.value.route.state === "active",
  );
  check(
    "response projects no private alias hash",
    !r.text.includes(first.alias_hash) && !r.text.includes("alias_hash") &&
      !r.text.includes("user_id"),
  );
  const original = await snapshot(first.id);
  r = await native(a, "create", first);
  check(
    "exact setup retry keeps route identity",
    r.status === 200 && r.value.route.id === first.id,
  );
  check(
    "exact retry leaves complete row unchanged",
    JSON.stringify(await snapshot(first.id)) === JSON.stringify(original),
  );
  check(
    "changed setup conflicts",
    (await native(a, "create", { ...first, name: "Changed retry" })).status ===
      409,
  );
  r = await native(b, "list");
  check(
    "other real account sees no owner routes",
    r.status === 200 && r.value.account === b.id && r.value.routes.length === 0,
  );
  check(
    "other real account cannot pause route",
    (await native(b, "pause", { id: first.id, revision: 1 })).status === 404,
  );
  check(
    "other real account cannot replay owner setup",
    (await native(b, "create", first)).status === 404,
  );
  result.phase = "session-recovery";
  const oldSession = a.session, oldToken = a.token;
  await database(
    `update auth.sessions set not_after=clock_timestamp()-interval '1 minute' where user_id=${
      lit(a.id)
    } and id=${lit(oldSession)} returning id`,
  );
  check(
    "actual expired server session refuses mutation",
    (await native(a, "pause", { id: first.id, revision: 1 })).status === 401,
  );
  check(
    "expired session leaves full route row unchanged",
    JSON.stringify(await snapshot(first.id)) === JSON.stringify(original),
  );
  check(
    "wrong password refuses renewal",
    (await signin(a, "synthetic-wrong-password")).status === 400,
  );
  assert.equal((await signin(a)).status, 200);
  check(
    "same account gets new actual session",
    a.session !== oldSession && a.token !== oldToken,
  );
  r = await native(a, "create", first);
  check(
    "renewed account retries original setup",
    r.status === 200 && r.value.route.id === first.id,
  );
  check(
    "renewal retry preserves full route fingerprint",
    JSON.stringify(await snapshot(first.id)) === JSON.stringify(original),
  );
  r = await native(a, "pause", { id: first.id, revision: 1 });
  check(
    "pause after renewal persists",
    r.status === 200 && r.value.route.state === "paused" &&
      r.value.route.revision === 2,
  );
  r = await native(a, "pause", { id: first.id, revision: 1 });
  check(
    "uncertain pause retry is idempotent",
    r.status === 200 && r.value.route.revision === 2,
  );
  check(
    "stale resume revision refused",
    (await native(a, "resume", { id: first.id, revision: 1, domain }))
      .status === 409,
  );
  r = await native(a, "resume", { id: first.id, revision: 2, domain });
  check(
    "reviewed resume persists",
    r.status === 200 && r.value.route.state === "active" &&
      r.value.route.revision === 3,
  );
  const replacement = draft(),
    rotation = { id: first.id, revision: 3, replacement };
  r = await native(a, "rotate", rotation);
  check(
    "rotation revokes original and returns replacement",
    r.status === 200 && r.value.route.id === replacement.id &&
      r.value.replaced.id === first.id && r.value.replaced.state === "revoked",
  );
  r = await native(a, "rotate", rotation);
  check(
    "rotation retry keeps one replacement",
    r.status === 200 && r.value.route.id === replacement.id,
  );
  check(
    "two retained route identities after rotation",
    (await database(
      `select count(*)::int as count from taskfold_private.email_routes where user_id=${
        lit(a.id)
      }`,
    ))[0].count === 2,
  );
  r = await native(a, "revoke", { id: replacement.id, revision: 1 });
  check(
    "terminal revocation persists",
    r.status === 200 && r.value.route.state === "revoked",
  );
  check(
    "revoked route cannot resume",
    (await native(a, "resume", { id: replacement.id, revision: 2, domain }))
      .status === 409,
  );
  const cancelled = draft();
  r = await native(a, "revoke", { id: cancelled.id, revision: 0 });
  check(
    "cancel before create persists",
    r.status === 200 && r.value.cancelled === true,
  );
  check(
    "discarded setup cannot be created",
    (await native(a, "create", cancelled)).status === 409,
  );
  check(
    "old session bearer remains refused",
    (await native({ ...a, token: oldToken }, "list")).status === 401,
  );
  check(
    "all hosted management preserves task snapshot",
    JSON.stringify(await tasks()) === JSON.stringify(initialTasks),
  );
  result.phase = "native-role-boundary";
  r = await api("/rest/v1/rpc/taskfold_email_routes", a.token, {
    _account: b.id,
    _session: b.session,
    _action: "list",
    _body: {},
  });
  check(
    "native cannot bypass gateway with direct RPC",
    r.status === 401 || r.status === 403 || r.status === 404,
  );
  r = await api("/rest/v1/rpc/taskfold_email_deliver_v2", a.token, {
    _alias_hash: first.alias_hash,
    _recipient_domain: domain,
    _provider: "synthetic-adapter",
    _delivery_id: "untrusted",
    _received_at: new Date().toISOString(),
    _verified_sender: a.email,
    _content: {
      title: "Never create",
      description: "Untrusted native delivery",
      attachmentCount: 0,
    },
  });
  check(
    "native cannot attest provider delivery",
    r.status === 401 || r.status === 403 || r.status === 404,
  );
  check(
    "no native delivery task created",
    JSON.stringify(await tasks()) === JSON.stringify(initialTasks),
  );
  const advisor = JSON.parse(
    await cli([
      "db",
      "advisors",
      "--db-url",
      config.POSTGRES_URL,
      "--type",
      "all",
      "--output",
      "json",
    ]),
  );
  result.advisors = advisor;
  result.passed = true;
  result.phase = "complete";
} catch (e) {
  result.passed = false;
  result.failure = { message: e.message };
  process.exitCode = 1;
} finally {
  try {
    await database(
      `select public.taskfold_email_configure('synthetic-adapter',${
        lit(domain)
      },false)`,
    );
    result.cleanup.configuration = true;
  } catch {
    result.cleanupFailure = "Synthetic configuration cleanup failed";
  }
  try {
    for (const user of users) {
      const r = await api(
        "/auth/v1/admin/users/" + user.id,
        config.SUPABASE_SERVICE_ROLE_KEY,
        undefined,
        "DELETE",
        config.SUPABASE_SERVICE_ROLE_KEY,
      );
      assert([200, 204, 404].includes(r.status));
    }
    result.cleanup.users = true;
  } catch {
    result.cleanupFailure = "Synthetic user cleanup failed";
  }
  try {
    if (deployed) {
      await cli([
        "functions",
        "delete",
        "email-routes",
        "--project-ref",
        project,
        "--yes",
      ]);
    }
    result.cleanup.function = true;
  } catch {
    result.cleanupFailure = "Owned function cleanup failed";
  }
  try {
    if (environmentSet) {
      await cli([
        "secrets",
        "unset",
        ...Object.keys(environment),
        "--project-ref",
        project,
        "--yes",
      ]);
    }
    result.cleanup.environment = true;
  } catch {
    result.cleanupFailure = "Owned environment cleanup failed";
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
  if (result.cleanupFailure) process.exitCode = 1;
}
