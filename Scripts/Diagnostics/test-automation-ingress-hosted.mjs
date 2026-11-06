// One-use hosted header probe. Private signing key stays in memory. No task/Auth/
// storage/database access, service key reads or project settings mutations.
import assert from "node:assert/strict";
import { generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const exec = promisify(execFile),
  project = "zqxflydiyfjeedqvyova",
  origin = "https://" + project + ".supabase.co";
const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const output = process.argv[2];
if (!output) throw new Error("Supply a summary output path");
const slug = "taskfold-ip-probe-" +
  randomUUID().replaceAll("-", "").slice(0, 12);
const stage = await mkdtemp(join(tmpdir(), "taskfold-ingress-probe-"));
const { publicKey, privateKey } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
});
const summary = {
  project,
  date: new Date().toISOString(),
  probe: slug,
  checks: {},
  productionAPIEnabled: false,
  realTasksChanged: 0,
  probeDeleted: false,
};
let checks = 0, deploymentAttempted = false;
const same = (name, condition) => {
  summary.checks[name] = !!condition;
  assert(condition, name);
  checks++;
};
const cli = async (args) =>
  JSON.parse(
    (await exec("supabase", args.concat(["--output", "json"]), {
      maxBuffer: 1024 * 1024,
      timeout: 60000,
    })).stdout || "null",
  );
const signed = (value) => {
  const body = JSON.stringify(value);
  return {
    body,
    signature: sign("sha256", Buffer.from(body), {
      key: privateKey,
      dsaEncoding: "ieee-p1363",
    }).toString("base64url"),
  };
};
const direct = () => ({ mode: "direct", at: Date.now(), nonce: randomUUID() });
async function call(value, headers = {}, overrideSignature) {
  const envelope = signed(value);
  const result = await fetch(origin + "/functions/v1/" + slug, {
    method: "POST",
    redirect: "error",
    signal: AbortSignal.timeout(10000),
    headers: {
      "Content-Type": "application/json",
      "X-Taskfold-Probe-Signature": overrideSignature ?? envelope.signature,
      ...headers,
    },
    body: envelope.body,
  });
  summary.lastHTTPStatus = result.status;
  if (!result.ok) {
    await result.body?.cancel();
    return { status: result.status, value: null };
  }
  const bytes = await result.arrayBuffer();
  summary.lastHTTPStatus = result.status;
  summary.lastResponseBytes = bytes.byteLength;
  if (bytes.byteLength > 4096) {
    throw new Error("Probe response exceeds bounded diagnostic schema");
  }
  return {
    status: result.status,
    value: (() => {
      try {
        return JSON.parse(Buffer.from(bytes).toString("utf8"));
      } catch {
        return null;
      }
    })(),
  };
}
try {
  const existing = await cli(["functions", "list", "--project-ref", project]);
  same("uniqueTemporarySlug", !existing.some((f) => f.slug === slug));
  for (
    const file of [
      "Scripts/Diagnostics/automation-ingress-probe.ts",
      "supabase/functions/_shared/automation-admission.ts",
    ]
  ) {
    await mkdir(dirname(join(stage, file)), { recursive: true, mode: 0o700 });
    await copyFile(join(repo, file), join(stage, file));
  }
  await mkdir(join(stage, "supabase/functions", slug), {
    recursive: true,
    mode: 0o700,
  });
  await writeFile(
    join(stage, "supabase/config.toml"),
    'project_id = "taskfold-ingress-diagnostics"\n',
    { mode: 0o600 },
  );
  const selfURL = origin + "/functions/v1/" + slug;
  const wrapper =
    'import {createIngressProbe} from "../../../Scripts/Diagnostics/automation-ingress-probe.ts";\nDeno.serve(createIngressProbe({publicKey:' +
    JSON.stringify(publicKey.export({ format: "jwk" })) + ",expires:" +
    (Date.now() + 15 * 60 * 1000) + ",selfURL:" + JSON.stringify(selfURL) +
    ',fingerprintKey:Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??""}));\n';
  await writeFile(
    join(stage, "supabase/functions", slug, "index.ts"),
    wrapper,
    { mode: 0o600 },
  );
  deploymentAttempted = true;
  await exec("supabase", [
    "functions",
    "deploy",
    slug,
    "--project-ref",
    project,
    "--no-verify-jwt",
    "--use-api",
    "--workdir",
    stage,
  ], { maxBuffer: 1024 * 1024, timeout: 60000 });
  let baseline;
  for (let n = 0; n < 3; n++) {
    baseline = await call(direct());
    if (baseline.status === 200) break;
    if (n < 2) await new Promise((r) => setTimeout(r, 1000));
  }
  same("authenticatedDirectProbe", baseline.status === 200);
  same("lastHopCanonical", baseline.value.canonicalLastHop);
  same("lastHopPublicOnHostRequest", baseline.value.lastPublic);
  same(
    "keyedFingerprintOnly",
    /^[a-f0-9]{64}$/.test(baseline.value.lastFingerprint),
  );
  same(
    "badSignatureRejected",
    (await call(direct(), {}, "A".repeat(86))).status === 401,
  );
  same(
    "expiredSignedRequestRejected",
    (await call({ ...direct(), at: Date.now() - 120000 })).status === 401,
  );
  const spoofed = await call(direct(), { "X-Forwarded-For": "192.0.2.222" });
  same("spoofedSingleStillAuthenticated", spoofed.status === 200);
  summary.headerBehavior = {
    baselineHopCount: baseline.value.hopCount,
    spoofedHopCount: spoofed.value.hopCount,
    spoofedPrefixRetained: spoofed.value.injectedInPrefix,
    spoofedLastIsInjected: spoofed.value.injectedInLast,
  };
  summary.phase = "forged-chain";
  const chain = await call(direct(), {
    "X-Forwarded-For": "198.51.100.88, 192.0.2.222",
  });
  summary.phase = "alternate-headers";
  const alternateResults = [];
  for (
    const header of [
      "X-Real-IP",
      "CF-Connecting-IP",
      "Forwarded",
      "True-Client-IP",
      "X-Client-IP",
      "X-Envoy-External-Address",
      "X-SB-Client-IP",
    ]
  ) {
    const result = await call(direct(), {
      [header]: header === "Forwarded" ? "for=192.0.2.222" : "192.0.2.222",
    });
    alternateResults.push(result);
    summary.alternateHeaderStatus ??= {};
    summary.alternateHeaderStatus[header] = result.status;
  }
  summary.phase = "relay";
  const child = signed(direct());
  const relayed = await call({
    mode: "relay",
    at: Date.now(),
    nonce: randomUUID(),
    child,
  });
  same(
    "secondNetworkProbeAuthenticated",
    relayed.status === 200 && relayed.value.relayed.canonicalLastHop,
  );
  const child2 = signed(direct());
  const relayedSpoof = await call({
    mode: "relay",
    at: Date.now(),
    nonce: randomUUID(),
    spoof: true,
    child: child2,
  });
  same(
    "forgedHeaderRequestsCompleted",
    chain.status === 200 && alternateResults.every((r) =>
      r.status === 200 || r.status === 403
    ) && relayedSpoof.status === 200,
  );
  const clean2 = await call(direct());
  same("repeatedCleanRequestCompleted", clean2.status === 200);
  summary.headerBehavior = {
    baselineHopCount: baseline.value.hopCount,
    spoofedHopCount: spoofed.value.hopCount,
    spoofedPrefixRetained: spoofed.value.injectedInPrefix,
    spoofedLastIsInjected: spoofed.value.injectedInLast,
    relayHopCount: relayed.value.relayed.hopCount,
  };
  summary.identitySurvey = {};
  for (const name of Object.keys(baseline.value.identities)) {
    const normal = baseline.value.identities[name],
      repeat = clean2.value.identities[name];
    const forged = [spoofed, chain, ...alternateResults];
    const remote = relayed.value.relayed.identities[name],
      remoteForged = relayedSpoof.value.relayed.identities[name];
    const observation = {
      present: normal.canonical,
      public: normal.public,
      stableAcrossClean: normal.fingerprint === repeat.fingerprint,
      unchangedByForgedHeaders: forged.every((r) =>
        r.status === 403 ||
        (r.status === 200 && r.value.identities[name].canonical &&
          !r.value.identities[name].injected &&
          r.value.identities[name].fingerprint === normal.fingerprint)
      ),
      differentOnSecondNetwork: remote.canonical &&
        remote.fingerprint !== normal.fingerprint,
      secondNetworkSpoofRejected: remoteForged.canonical &&
        !remoteForged.injected,
    };
    observation.trustedCandidate = observation.present && observation.public &&
      observation.stableAcrossClean && observation.unchangedByForgedHeaders &&
      observation.differentOnSecondNetwork &&
      observation.secondNetworkSpoofRejected;
    summary.identitySurvey[name] = observation;
  }
  summary.verifiedCandidates = Object.keys(summary.identitySurvey).filter((k) =>
    summary.identitySurvey[k].trustedCandidate
  );
  summary.productionPairVerified = baseline.value.productionPairVerified &&
    clean2.value.productionPairVerified &&
    spoofed.value.productionPairVerified &&
    chain.value.productionPairVerified && alternateResults.every((r) =>
      r.status === 403 || r.value.productionPairVerified
    ) && relayed.value.relayed.productionPairVerified &&
    relayedSpoof.value.relayed.productionPairVerified;
  same(
    "actualProductionHeaderPairMatchesAcrossBothNetworks",
    summary.productionPairVerified,
  );
  summary.trustedLastHopVerified =
    summary.identitySurvey.xff_last.trustedCandidate;
  same("atLeastOneNonSpoofableSource", summary.verifiedCandidates.length > 0);
} catch (error) {
  summary.failed = true;
  summary.errorType = error.name;
  summary.failure = error instanceof assert.AssertionError
    ? error.message
    : "Hosted probe execution failed; inspect retained operational status, not credentials";
  process.exitCode = 1;
} finally {
  if (deploymentAttempted) {
    try {
      await exec("supabase", [
        "functions",
        "delete",
        slug,
        "--project-ref",
        project,
        "--yes",
      ], { maxBuffer: 1024 * 1024, timeout: 60000 });
    } catch { /* Cleanup outcome is verified independently by listing. */ }
    try {
      const remaining = await cli([
        "functions",
        "list",
        "--project-ref",
        project,
      ]);
      summary.probeDeleted = !remaining.some((f) => f.slug === slug);
    } catch { /* Absence must be positively verified before success. */ }
  } else summary.probeDeleted = true;
  if (!summary.probeDeleted) {
    summary.cleanupRequired = true;
    process.exitCode = 1;
  }
  summary.assertions = checks;
  await writeFile(resolve(output), JSON.stringify(summary, null, 2) + "\n", {
    mode: 0o600,
  });
  await rm(stage, { recursive: true, force: true });
  console.log(
    JSON.stringify({
      assertions: checks,
      passed: !summary.failed,
      probeDeleted: summary.probeDeleted,
      summary: resolve(output),
    }),
  );
}
