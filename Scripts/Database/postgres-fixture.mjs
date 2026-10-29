// Owned synthetic PostgreSQL runtime. No public ports, mounted user files or credentials.
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
const exec = promisify(execFile);
export const postgresImage =
  "postgres@sha256:ef257d85f76e48da1c64832459b59fcaba1a4dac97bf5d7450c77753542eee94";
export const literal = (value) =>
  "'" + String(value).replaceAll("'", "''") + "'";
export async function createPostgresFixture(
  { advisors = false, cronDirectory = null, cronBackgroundWorkers = false } =
    {},
) {
  await exec("python3", [fileURLToPath(new URL("../check_test_storage.py", import.meta.url)), "--path", "/tmp"]);
  const name = "taskfold-task-pg-" + randomUUID().slice(0, 8),
    label = randomUUID(),
    holders = new Set();
  let created = false;
  const psql = [
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
  ];
  const raw = async (query) => {
    try {
      return (await exec("docker", ["exec", name, ...psql, "-c", query], {
        timeout: 20000,
        maxBuffer: 1024 * 1024,
      })).stdout.trim();
    } catch (error) {
      const failure = new Error("Owned PostgreSQL query failed");
      failure.code = /ERROR:\s+([A-Z0-9]{5}):/.exec(error.stderr ?? "")?.[1] ??
        error.code;
      throw failure;
    }
  };
  const scalar = async (query) => JSON.parse(await raw(query));
  async function close() {
    // A failed control statement must never prevent owned-container cleanup
    // or replace the test's primary error with a cleanup error.
    for (const holder of [...holders]) {
      try { await holder.release("rollback"); } catch { /* Removal below closes every owned backend. */ }
    }
    if (created) {
      const state = JSON.parse(
        (await exec("docker", ["inspect", name], { timeout: 5000 })).stdout,
      )[0];
      if (state.Config.Labels["com.taskfold.fixture"] !== label) {
        throw new Error("Fixture ownership mismatch");
      }
      await exec("docker", ["rm", "--force", name], { timeout: 10000 });
      created = false;
    }
    return (await exec("docker", [
      "ps",
      "-a",
      "--filter",
      "name=^/" + name + "$",
      "--format",
      "{{.Names}}",
    ], { timeout: 5000 })).stdout.trim() === "";
  }
  function value(
    expression,
    { role = "service_role", app = "taskfold-" + randomUUID().slice(0, 8) } =
      {},
  ) {
    if (
      !["service_role", "postgres"].includes(role) ||
      !/^[a-z0-9_-]{1,63}$/.test(app)
    ) throw new Error("Invalid worker identity");
    const delimiter = "$fixture_" + randomUUID().replaceAll("-", "") + "$";
    return scalar(
      `set application_name=${
        literal(app)
      };set role ${role};create temp table taskfold_fixture_result(value jsonb,code text,reason text) on commit drop;
  do ${delimiter} begin begin insert into taskfold_fixture_result values((${expression}),null,null);exception when others then insert into taskfold_fixture_result values(null,sqlstate,left(sqlerrm,200));end;end ${delimiter};
  select jsonb_build_object('pid',pg_backend_pid(),'value',value,'code',code,'reason',reason) from taskfold_fixture_result;`,
    );
  }
  async function hold(sql) {
    const marker = randomUUID(),
      child = spawn("docker", ["exec", "-i", name, ...psql], {
        stdio: ["pipe", "pipe", "pipe"],
      });
    let buffer = "", ready = false, pid, stderr = "";
    child.stderr.on("data", part => { stderr = (stderr + part).slice(-65536); });
    const acquired = new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("Control lock not acquired")),
        5000,
      );
      child.once("error", reject);
      child.once("exit", () => {
        if (!ready) {
          clearTimeout(timer);
          const failure = new Error("Control session closed early");
          failure.code = /ERROR:\s+([A-Z0-9]{5}):/.exec(stderr)?.[1]; reject(failure);
        }
      });
      child.stdout.on("data", (part) => {
        buffer += part;
        for (const line of buffer.split("\n")) {
          try {
            const row = JSON.parse(line);
            if (row.marker === marker) {
              clearTimeout(timer);
              ready = true;
              pid = row.pid;
              resolve();
            }
          } catch { /* Ignore non-marker SQL command output. */ }
        }
      });
    });
    const holder = {
      get pid() {
        return pid;
      },
      async release(mode = "commit", before = "") {
        if (!holders.has(holder)) return;
        holders.delete(holder);
        if (child.exitCode === null) child.stdin.end(
          before + ";" + (mode === "commit" ? "commit" : "rollback") + ";\n",
        );
        if (child.exitCode === null) await Promise.race([
          once(child, "exit"),
          new Promise((r) => setTimeout(r, 5000)),
        ]);
        if (child.exitCode === null) {
          child.kill("SIGTERM");
          throw new Error("Control session did not exit");
        }
        if (child.exitCode !== 0) {
          const failure = new Error("Control transaction failed");
          failure.code = /ERROR:\s+([A-Z0-9]{5}):/.exec(stderr)?.[1];
          throw failure;
        }
      },
    };
    holders.add(holder);
    child.stdin.write(
      `begin;${sql};select jsonb_build_object('marker',${
        literal(marker)
      },'pid',pg_backend_pid());\n`,
    );
    try { await acquired; }
    catch (error) { try { await holder.release("rollback"); } catch { /* Preserve the query failure. */ } throw error; }
    return holder;
  }
  async function waitForLock(app, blocker) {
    for (let n = 0; n < 40; n++) {
      const row = await scalar(
        `select coalesce((select jsonb_build_object('pid',pid,'event',wait_event,'blockers',pg_blocking_pids(pid)) from pg_stat_activity where application_name=${
          literal(app)
        } and wait_event_type='Lock'),'null'::jsonb)`,
      );
      if (row && (blocker === undefined || row.blockers.includes(blocker))) {
        return row;
      }
      await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error("Worker did not reach expected database lock");
  }

  try {
    await exec("docker", ["info", "--format", "{{.ServerVersion}}"], {
      timeout: 5000,
    });
    try {
      await exec("docker", ["image", "inspect", postgresImage], {
        timeout: 5000,
      });
    } catch {
      await exec("docker", ["pull", postgresImage], {
        timeout: 60000,
        maxBuffer: 1024 * 1024,
      });
    }
    await exec("docker", [
      "run",
      "--detach",
      "--rm",
      "--network",
      advisors ? "bridge" : "none",
      ...(advisors ? ["--publish", "127.0.0.1::5432"] : []),
      "--tmpfs",
      "/var/lib/postgresql/data:rw,size=256m",
      "--memory",
      "512m",
      "--cpus",
      "1",
      "--name",
      name,
      "--label",
      "com.taskfold.fixture=" + label,
      "-e",
      "POSTGRES_HOST_AUTH_METHOD=trust",
      ...(cronDirectory
        ? [
          "--mount",
          `type=bind,src=${cronDirectory}/pg_cron.so,dst=/usr/local/lib/postgresql/pg_cron.so,readonly`,
          "--mount",
          `type=bind,src=${cronDirectory}/extension,dst=/usr/local/share/postgresql/extension,readonly`,
        ]
        : []),
      postgresImage,
      "postgres",
      "-c",
      "max_connections=40",
      "-c",
      "shared_buffers=32MB",
      ...(cronDirectory
        ? [
          "-c",
          "shared_preload_libraries=pg_cron",
          "-c",
          "cron.database_name=postgres",
          "-c",
          `cron.use_background_workers=${cronBackgroundWorkers ? "on" : "off"}`,
        ]
        : []),
    ], { timeout: 15000 });
    created = true;
    let ready = false;
    for (let n = 0; n < 100; n++) {
      try {
        const log = await exec("docker", ["logs", name], {
          timeout: 1000,
          maxBuffer: 65536,
        });
        if (
          !(log.stdout + log.stderr).includes(
            "PostgreSQL init process complete; ready for start up.",
          )
        ) throw new Error("Initializing");
        await exec("docker", ["exec", name, "pg_isready", "-U", "postgres"], {
          timeout: 1000,
        });
        ready = true;
        break;
      } catch {
        await new Promise((r) => setTimeout(r, 100));
      }
    }
    if (!ready) throw new Error("Owned database did not initialize");
    const serverVersion = await scalar(
      "select to_jsonb(current_setting('server_version_num')::int)",
    );
    if (serverVersion !== 170006) {
      throw new Error("Unexpected PostgreSQL version");
    }
    return {
      raw,
      scalar,
      value,
      hold,
      waitForLock,
      close,
      serverVersion,
      // Optional read-only CLI advisors on this exact owned fixture. Explicit
      // opt-in publishes an ephemeral loopback-only port; no user data.
      advisors: async () => {
        if (!advisors) {
          throw new Error("Advisor probe requires explicit fixture opt-in");
        }
        return (await import("./postgres-advisors.mjs")).runPostgresAdvisors(
          name,
          label,
        );
      },
    };
  } catch (error) {
    await close();
    throw error;
  }
}
