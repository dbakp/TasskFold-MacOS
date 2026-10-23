// Runs only the owned synthetic transport probe. CLI credentials remain in
// memory; output projects fixed booleans/statuses, never keys or response bodies.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile, stat, writeFile } from "node:fs/promises";
const [branchID, output, privateTokenFile] = process.argv.slice(2);
assert(
  branchID && output && privateTokenFile,
  "Supply owned acceptance branch ID, output path and private token env file",
);
assert(
  ((await stat(privateTokenFile)).mode & 0o077) === 0,
  "Owner-private token file required",
);
const acceptanceToken = /^TASKFOLD_WEBHOOK_ACCEPTANCE_TOKEN=([a-f0-9]{64})\n?$/
  .exec(await readFile(privateTokenFile, "utf8"))?.[1];
assert(acceptanceToken, "Private acceptance token required");
const cli = async (args) => {
  try {
    return JSON.parse(
      (await promisify(execFile)("supabase", args, {
        timeout: 90000,
        maxBuffer: 1048576,
      })).stdout,
    );
  } catch {
    throw Error("Acceptance CLI action failed");
  }
};
const parent = "zqxflydiyfjeedqvyova";
const branches = await cli([
  "branches",
  "list",
  "--project-ref",
  parent,
  "--output",
  "json",
]);
const branch = branches.find((b) => b.id === branchID);
assert(
  branch && !branch.is_default && !branch.persistent &&
    branch.with_data === false &&
    branch.name.startsWith("codex-webhook-transport-acceptance-"),
  "Owned data-excluding acceptance branch required",
);
const config = await cli([
  "branches",
  "get",
  branchID,
  "--project-ref",
  parent,
  "--output",
  "json",
]);
assert(
  config.SUPABASE_URL === `https://${branch.project_ref}.supabase.co` &&
    branch.project_ref !== parent,
  "Refuse primary or unrelated host",
);
const summary = {
  date: new Date().toISOString(),
  branchId: branchID,
  project: branch.project_ref,
  realTasksChanged: 0,
  passed: false,
  checks: {},
  outcomes: {},
};
try {
  for (
    const [name, suffix] of [["sender-requires-private-token", ""], [
      "receiver-requires-signature",
      "/delivery",
    ]]
  ) {
    const rejected = await fetch(
      config.SUPABASE_URL + "/functions/v1/webhook-transport-probe" + suffix,
      {
        method: "POST",
        redirect: "error",
        signal: AbortSignal.timeout(10000),
        headers: { apikey: config.SUPABASE_ANON_KEY },
      },
    );
    summary.checks[name] = rejected.status === 401;
    await rejected.body?.cancel();
  }
  const response = await fetch(
    config.SUPABASE_URL + "/functions/v1/webhook-transport-probe",
    {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(90000),
      headers: {
        "X-Taskfold-Acceptance": acceptanceToken,
        apikey: config.SUPABASE_ANON_KEY,
      },
    },
  );
  assert(response.status === 200, "Hosted probe did not return success");
  const data = await response.json();
  summary.diagnostics = Object.fromEntries(
    Object.entries(data.diagnostics ?? {}).filter(([key, value]) =>
      ["dns", "socket"].includes(key) && typeof value === "string" &&
      /^[A-Z_]{3,64}$/.test(value)
    ),
  );
  summary.checks.secretEnvelope = data.checks?.secretEnvelope === true;
  for (
    const mode of [
      "delivery",
      "challenge",
      "redirect",
      "gone",
      "retry",
      "oversize",
    ]
  ) {
    summary.checks[mode] = data.checks?.[mode] === true;
    const result = data.outcomes?.[mode];
    summary.outcomes[mode] = {
      outcome:
        ["delivered", "retry", "refused", "gone"].includes(result?.outcome)
          ? result.outcome
          : "unknown",
      ...(Number.isInteger(result?.status) && result.status >= 100 &&
          result.status < 600
        ? { status: result.status }
        : {}),
    };
  }
  assert(
    Object.values(summary.checks).every(Boolean),
    "Hosted transport assertion failed",
  );
  summary.passed = true;
} catch {
  summary.failure =
    "Hosted transport probe did not pass; no private diagnostic recorded";
  process.exitCode = 1;
} finally {
  await writeFile(output, JSON.stringify(summary, null, 2) + "\n", {
    mode: 0o600,
  });
  console.log(JSON.stringify(summary));
}
