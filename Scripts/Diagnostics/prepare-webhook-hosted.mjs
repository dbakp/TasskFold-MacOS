// No-data preview branch only. Credentials never appear in output or source.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
const [connectionPath, output] = process.argv.slice(2);
assert(
  connectionPath && output,
  "Supply private branch connection and summary paths",
);
const exec = promisify(execFile),
  repo = resolve(dirname(fileURLToPath(import.meta.url)), "../.."),
  parent = "zqxflydiyfjeedqvyova";
assert(
  ((await stat(connectionPath)).mode & 0o077) === 0,
  "Private connection required",
);
const config = JSON.parse(await readFile(connectionPath, "utf8")),
  project = new URL(config.SUPABASE_URL).hostname.split(".")[0];
assert(
  /^[a-z]{20}$/.test(project) && project !== parent &&
    config.SUPABASE_URL === `https://${project}.supabase.co`,
  "Refuse primary host",
);
const database = new URL(config.POSTGRES_URL);
assert(
  ["postgres:", "postgresql:"].includes(database.protocol) &&
    ((database.hostname === `db.${project}.supabase.co` &&
      database.username === "postgres") ||
      (/^aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com$/.test(
        database.hostname,
      ) &&
        decodeURIComponent(database.username) === `postgres.${project}`)),
  "Database must belong to the owned preview project",
);
const branches = JSON.parse(
    (await exec("supabase", [
      "branches",
      "list",
      "--project-ref",
      parent,
      "--output",
      "json",
    ])).stdout,
  ),
  branch = branches.find((b) => b.project_ref === project);
assert(
  branch && !branch.is_default && !branch.persistent &&
    branch.with_data === false &&
    branch.name.startsWith("codex-webhook-delivery-acceptance-"),
  "Refuse unowned branch",
);
const root = dirname(resolve(connectionPath));
await mkdir(join(root, "supabase"), { recursive: true, mode: 0o700 });
await writeFile(
  join(root, "supabase/config.toml"),
  'project_id="taskfold-webhook-hosted"\n',
  { mode: 0o600 },
);
async function query(sql) {
  const file = join(root, "query.sql");
  await writeFile(file, sql, { mode: 0o600 });
  try {
    return (await exec("supabase", [
      "db",
      "query",
      "--db-url",
      config.POSTGRES_URL,
      "--file",
      file,
      "--output",
      "json",
    ], { timeout: 90000, maxBuffer: 1048576 })).stdout;
  } catch (error) {
    let message = error.stderr ?? "";
    for (const v of Object.values(config)) {
      if (typeof v === "string" && v.length > 15) {
        message = message.replaceAll(v, "[private]");
      }
    }
    message = message.replaceAll(
      new URL(config.POSTGRES_URL).password,
      "[private]",
    );
    throw Error(message.slice(-1200));
  }
}
// Earlier platform histories differ. The inspected native-base bridge above
// supplies their shared prerequisites; verify the common feature migrations.
const versions = (await readdir(join(repo, "supabase/migrations"))).filter(
    (n) => n.endsWith(".sql") && n >= "20261006000000",
  ).sort(),
  hashes = {};
for (const file of versions) {
  hashes[file] = createHash("sha256").update(
    await readFile(join(repo, "supabase/migrations", file)),
  ).digest("hex");
}
const state = await query(
  "select to_regclass('taskfold_private.webhook_outbox') is not null as installed",
);
if (JSON.parse(state).rows[0].installed !== true) {
  let sql = await readFile(
    join(repo, "Scripts/Diagnostics/webhook-hosted-base.sql"),
    "utf8",
  );
  for (const file of versions) {
    sql += "\n" +
      await readFile(join(repo, "supabase/migrations", file), "utf8");
  }
  await query(
    "do $taskfold_hosted_schema$ begin\n" + sql +
      "\nend $taskfold_hosted_schema$;",
  );
}
const fixture = await query(
  "select to_regclass('taskfold_webhook_acceptance.messages') is not null as installed",
);
if (JSON.parse(fixture).rows[0].installed !== true) {
  await query(
    "do $taskfold_hosted_receiver$ begin\n" +
      await readFile(
        join(repo, "Scripts/Diagnostics/webhook-hosted-receiver.sql"),
        "utf8",
      ) + "\nend $taskfold_hosted_receiver$;",
  );
}
const result = await query(
  "select to_regclass('taskfold_private.webhook_outbox') is not null as outbox_installed, to_regclass('taskfold_webhook_acceptance.messages') is not null as receiver_installed,not exists(select 1 from cron.job where jobname='taskfold-native-reminder-sweep' and active) as reminder_worker_disabled,not exists(select 1 from vault.decrypted_secrets where name in('taskfold_reminder_cron_secret','taskfold_reminder_project_url')) as no_reminder_credentials,not has_function_privilege('authenticated','public.taskfold_webhook_dispatch(text,jsonb)','EXECUTE') as native_worker_denied",
);
const installed = JSON.parse(result).rows[0];
assert(
  Object.values(installed).every((value) => value === true),
  "Private installation gate failed",
);
await writeFile(
  output,
  JSON.stringify(
    {
      date: new Date().toISOString(),
      project,
      branchId: branch.id,
      migrationHashes: hashes,
      installed,
      realTasksChanged: 0,
      mainChanged: false,
    },
    null,
    2,
  ) + "\n",
);
console.log("Owned preview source and receiver schema verified");
