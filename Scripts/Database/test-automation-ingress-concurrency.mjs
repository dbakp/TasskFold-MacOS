// Real PostgreSQL 17.6, independent psql connections, isolated Docker container.
// Uses no hosted credentials, host ports, shared database or mounted user files.
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
const exec = promisify(execFile),
  image =
    "postgres@sha256:ef257d85f76e48da1c64832459b59fcaba1a4dac97bf5d7450c77753542eee94";
const name = "taskfold-ingress-pg-" + randomUUID().slice(0, 8),
  label = randomUUID(),
  output = process.argv[2];
const summary = {
  date: new Date().toISOString(),
  image,
  checks: {},
  hostedAcceptance: false,
  realTasksChanged: 0,
  containerRemoved: false,
};
let checks = 0, created = false;
const same = (name, condition) => {
  summary.checks[name] = !!condition;
  assert(condition, name);
  checks++;
};
const hex = (n) => n.toString(16).padStart(64, "0");
const zero = hex(0), ip = hex(1), credential = hex(2);
async function sql(query, json = true) {
  try {
    const result = await exec("docker", [
      "exec",
      name,
      "psql",
      "-X",
      "-qAt",
      "-v",
      "ON_ERROR_STOP=1",
      "-v",
      "VERBOSITY=verbose",
      "-U",
      "postgres",
      "-d",
      "postgres",
      "-c",
      query,
    ], { timeout: 15000, maxBuffer: 1024 * 1024 });
    return json ? JSON.parse(result.stdout.trim()) : result.stdout;
  } catch (error) {
    const failure = new Error("Fixture SQL failed");
    failure.code = /ERROR:\s+([A-Z0-9]{5}):/.exec(error.stderr ?? "")?.[1] ??
      error.code;
    throw failure;
  }
}
const call = (route, source, token) =>
  sql(
    `set role service_role;select jsonb_build_object('pid',pg_backend_pid(),'receipt',public.taskfold_automation_admit('${route}','${source}','${token}'))`,
  );
async function freshWindow() {
  const remaining = 60000 - Date.now() % 60000;
  if (remaining < 10000) {
    await new Promise((r) => setTimeout(r, remaining + 100));
  }
}
try {
  summary.phase = "runtime";
  await exec("docker", ["info", "--format", "{{.ServerVersion}}"], {
    timeout: 5000,
  });
  // Pin the exact artifact. A missing image can be fetched without a package install.
  try {
    await exec("docker", ["image", "inspect", image], { timeout: 5000 });
  } catch {
    await exec("docker", ["pull", image], {
      timeout: 60000,
      maxBuffer: 1024 * 1024,
    });
  }
  await exec("docker", [
    "run",
    "--detach",
    "--rm",
    "--network",
    "none",
    "--tmpfs",
    "/var/lib/postgresql/data:rw,size=128m",
    "--memory",
    "384m",
    "--cpus",
    "1",
    "--name",
    name,
    "--label",
    "com.taskfold.fixture=" + label,
    "-e",
    "POSTGRES_HOST_AUTH_METHOD=trust",
    image,
    "postgres",
    "-c",
    "max_connections=40",
    "-c",
    "shared_buffers=32MB",
  ], { timeout: 15000 });
  created = true;
  let ready = false;
  for (let n = 0; n < 100; n++) {
    try {
      const log=await exec("docker",["logs",name],{timeout:1000,maxBuffer:65536});
      if(!(log.stdout+log.stderr).includes("PostgreSQL init process complete; ready for start up."))throw new Error("Initialization still running");
      await exec("docker", ["exec", name, "pg_isready", "-U", "postgres"], {
        timeout: 1000,
      });
      ready = true;
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  same("privateRuntimeReady", ready);
  summary.postgresVersion = await sql(
    "select to_jsonb(current_setting('server_version_num')::int)",
  );
  same("matchesHostedPostgres17_6", summary.postgresVersion === 170006);
  await sql(
    "create role anon;create role authenticated;create role service_role;create schema taskfold_private;grant usage on schema taskfold_private to service_role",
    false,
  );
  await sql(
    await readFile(
      new URL(
        "../../supabase/migrations/20261023012417_automation_ingress_limits.sql",
        import.meta.url,
      ),
      "utf8",
    ),
    false,
  );
  summary.phase = "concurrent-budgets";
  summary.concurrentBatches = [];
  for (const dimension of ["global", "ip", "credential"]) {
    await freshWindow();
    await sql("truncate taskfold_private.automation_ingress", false);
    const fingerprint = dimension === "global"
      ? zero
      : dimension === "ip"
      ? ip
      : credential;
    const cap = dimension === "global" ? 1200 : 120;
    await sql(
      `insert into taskfold_private.automation_ingress values('tasks','${dimension}','${fingerprint}',date_trunc('minute',clock_timestamp()),${
        cap - 1
      },date_trunc('minute',clock_timestamp())+interval '3 minutes')`,
      false,
    );
    const results = await Promise.all(
      Array.from({ length: 12 }, (_, i) =>
        call(
          "tasks",
          dimension === "ip" ? ip : hex(i + 100),
          dimension === "credential" ? credential : hex(i + 200),
        )),
    );
    const accepted = results.filter((r) => r.receipt.allowed),
      denied = results.filter((r) => !r.receipt.allowed);
    same(dimension + "ExactlyOneWins", accepted.length === 1);
    same(
      dimension + "ElevenDenied",
      denied.length === 11 &&
        denied.every((r) => r.receipt.limited_by === dimension),
    );
    same(
      dimension + "SeparateConnections",
      new Set(results.map((r) => r.pid)).size === 12,
    );
    const count = await sql(
      `select to_jsonb(hits) from taskfold_private.automation_ingress where route='tasks' and dimension='${dimension}' and fingerprint='${fingerprint}'`,
    );
    same(dimension + "NeverOvershoots", count === cap);
    summary.concurrentBatches.push({
      dimension,
      connections: 12,
      accepted: 1,
      denied: 11,
      finalCounter: count,
    });
    if (dimension === "global") {
      same(
        "ManagementIndependentOfSaturatedTaskRoute",
        (await call("keys", ip, credential)).receipt.allowed,
      );
    }
  }
  summary.phase = "lock-timeout";
  await sql("truncate taskfold_private.automation_ingress", false);
  const holder = spawn("docker", [
    "exec",
    "-i",
    name,
    "psql",
    "-X",
    "-qAt",
    "-v",
    "ON_ERROR_STOP=1",
    "-U",
    "postgres",
    "-d",
    "postgres",
  ], { stdio: ["pipe", "pipe", "pipe"] });
  let holderReady = false;
  try {
    const locked = new Promise((resolve, reject) => {
      let buffer = "";
      const timer = setTimeout(
        () => reject(new Error("Holder did not acquire lock")),
        5000,
      );
      holder.once("error", reject);
      holder.stdout.on("data", (chunk) => {
        buffer += chunk;
        for (const line of buffer.split("\n")) {
          if (line.includes("LOCK_READY")) {
            clearTimeout(timer);
            holderReady = true;
            resolve();
          }
        }
      });
    });
    holder.stdin.write(
      "begin;select pg_advisory_xact_lock(hashtextextended('automation-ingress:tasks',11820));select 'LOCK_READY';\n",
    );
    await locked;
    const started = performance.now();
    let code;
    try {
      await call("tasks", ip, credential);
    } catch (error) {
      code = error.code;
    }
    same("ActualAdvisoryWaitTimesOut", code === "55P03");
    same("WaitIsBounded", performance.now() - started < 3000);
    same(
      "TimedOutAdmissionAllocatesNoRows",
      await sql(
        "select to_jsonb(count(*)::int) from taskfold_private.automation_ingress",
      ) === 0,
    );
  } finally {
    if (holderReady) holder.stdin.end("rollback;\n");
    else holder.stdin.end();
    await Promise.race([
      once(holder, "exit"),
      new Promise((resolve) => setTimeout(resolve, 3000)),
    ]);
    if (holder.exitCode === null) holder.kill("SIGTERM");
  }
  same(
    "AdmissionRecoversAfterHolderRelease",
    (await call("tasks", ip, credential)).receipt.allowed,
  );
  await sql("truncate taskfold_private.automation_ingress", false);
  same(
    "SyntheticRowsCleared",
    await sql(
      "select to_jsonb(count(*)::int) from taskfold_private.automation_ingress",
    ) === 0,
  );
} catch (error) {
  summary.failed = true;
  summary.failure = error instanceof assert.AssertionError
    ? error.message
    : "Real PostgreSQL fixture failed";
  summary.errorCode = error.code;
  process.exitCode = 1;
} finally {
  if (created) {
    const inspected = JSON.parse(
      (await exec("docker", ["inspect", name], {
        timeout: 5000,
        maxBuffer: 1024 * 1024,
      })).stdout,
    )[0];
    if (inspected.Config.Labels["com.taskfold.fixture"] !== label) {
      summary.cleanupOwnershipFailed = true;
      process.exitCode = 1;
    }
    if (!summary.cleanupOwnershipFailed) {
      await exec("docker", ["rm", "--force", name], { timeout: 10000 });
    }
  }
  const remaining = (await exec("docker", [
    "ps",
    "-a",
    "--filter",
    "name=^/" + name + "$",
    "--format",
    "{{.Names}}",
  ], { timeout: 5000 })).stdout.trim();
  summary.containerRemoved = remaining === "";
  if (!summary.containerRemoved) process.exitCode = 1;
  summary.assertions = checks;
  if (output) {
    await writeFile(output, JSON.stringify(summary, null, 2) + "\n", {
      mode: 0o600,
    });
  }
  console.log(
    JSON.stringify({
      passed: !summary.failed,
      assertions: checks,
      containerRemoved: summary.containerRemoved,
      summary: output,
    }),
  );
}
