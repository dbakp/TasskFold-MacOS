// Hosted, no-data preview acceptance. Faults exist only in temporary entrypoints;
// the handler, dispatcher, Auth, SQL, encryption and TLS receiver stay real.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

export async function runWebhookServiceRecovery(c) {
  assert(/^[a-z]{20}$/.test(c.project) && c.project !== "zqxflydiyfjeedqvyova");
  const faultSlugs = {};
  for (const fault of ["missing", "corrupt"]) {
    for (const role of ["manager", "worker"]) {
      const slug = `webhook-acceptance-${role}-${fault}`;
      faultSlugs[`${role}-${fault}`] = slug;
      const directory = join(c.stage, "supabase/functions", slug);
      await mkdir(directory, { recursive: true, mode: 0o700 });
      const constructor = role === "worker"
        ? "createWebhookWorker"
        : "createWebhookHandler";
      const module = role === "worker" ? "worker" : "handler";
      const source =
        `import { ${constructor} } from '../automation-webhooks/${module}.ts';
import { webhookMasterCatalog } from '../automation-webhooks/master-config.ts';
const url=Deno.env.get('SUPABASE_URL')??'';
const owned=url==='https://${c.project}.supabase.co' && Deno.env.get('TASKFOLD_WEBHOOK_ACCEPTANCE_PROJECT')==='${c.project}';
const masterKeys=webhookMasterCatalog(Deno.env.get('TASKFOLD_WEBHOOK_MASTER_KEYS')??'{}');
${
          fault === "missing"
            ? "for(const key of Object.keys(masterKeys)){masterKeys[key].fill(0);delete masterKeys[key];}"
            : "for(const key of Object.values(masterKeys))key[0]^=1;"
        }
const config={url,serviceKey:Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')??'',
  forwardedForMode:Deno.env.get('TASKFOLD_AUTOMATION_FORWARDED_FOR_MODE')??'',
  currentMasterVersion:Deno.env.get('TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION')??'',
  workerToken:Deno.env.get('TASKFOLD_WEBHOOK_WORKER_TOKEN')??'',enabled:true,masterKeys};
const handler=${constructor}(config);
Deno.serve(owned?handler:()=>new Response('Unavailable',{status:503}));
`;
      await writeFile(join(directory, "index.ts"), source, { mode: 0o600 });
      c.deployed.push(slug); // Cleanup even when deployment loses its reply.
      await c.cli([
        "functions",
        "deploy",
        slug,
        "--project-ref",
        c.project,
        "--use-api",
        "--workdir",
        c.stage,
        ...(role === "worker" ? ["--no-verify-jwt"] : []),
      ]);
    }
  }
  const faultManager = (fault, user, action, body = {}) =>
    c.api(
      `/functions/v1/${faultSlugs[`manager-${fault}`]}`,
      user.token,
      { action, body },
      "POST",
      c.anon,
      { "X-Taskfold-Automation": "1" },
    );
  const faultWorker = (fault, token = c.workerToken) =>
    c.api(
      `/functions/v1/${faultSlugs[`worker-${fault}`]}`,
      token,
      {},
    );
  const uuid = /^[a-f0-9-]{36}$/;
  const subscriptionFingerprint = async (id) => {
    assert(uuid.test(id));
    const rows = await c.database(
      `select md5(row(id,revision,name,endpoint,scope,project_id,events,ttl_days,secret_hash,secret_envelope,created_at,expires_at)::text) as fingerprint from taskfold_private.webhook_subscriptions where id='${id}'`,
    );
    assert.equal(rows.length, 1, "Expected exactly one original subscription");
    return rows[0].fingerprint;
  };
  const eventFingerprint = async (id) => {
    assert(uuid.test(id));
    const rows = await c.database(
      `select md5(row(id,subscription_id,task_id,task_generation,event_type,payload,payload_sha256,created_at,expires_at)::text) as fingerprint from taskfold_private.webhook_outbox where id='${id}'`,
    );
    assert.equal(rows.length, 1, "Expected exactly one original queued event");
    return rows[0].fingerprint;
  };

  // All these credentials and tasks belong to this invocation's disposable users.
  const draft = {
    id: randomUUID(),
    name: "Service recovery proof",
    endpoint: c.receiverURL("receive"),
    scope: "inbox",
    project_id: null,
    events: ["task.created"],
    ttl_days: 30,
    secret: "tfwh_v1_" + c.secret.toString("base64url"),
  };
  assert.equal((await c.native(c.a, "create", draft)).status, 200);
  const original = await subscriptionFingerprint(draft.id);

  // Expire the actual server-side session, without minting or modifying a JWT.
  // This is not a wall-clock JWT-expiry or native refresh-token acceptance claim.
  await c.database(
    `update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id='${c.a.sid}' and user_id='${c.a.id}' returning id`,
  );
  for (
    const [action, body] of [["list", {}], ["create", draft], ["revoke", {
      id: draft.id,
    }]]
  ) {
    c.check(
      `expired-server-session-refuses-${action}`,
      (await c.native(c.a, action, body)).status === 401,
    );
  }
  c.check(
    "expired-session-keeps-exact-enrollment",
    await subscriptionFingerprint(draft.id) === original,
  );
  const expiredSession = c.a.sid;
  await c.signin(c.a);
  c.check("fresh-signin-uses-new-server-session", c.a.sid !== expiredSession);
  c.check(
    "same-enrollment-reconfirms-after-signin",
    (await c.native(c.a, "create", draft)).status === 200 &&
      await subscriptionFingerprint(draft.id) === original,
  );
  c.check(
    "other-account-cannot-recover-enrollment",
    (await c.native(c.b, "revoke", { id: draft.id })).status === 404,
  );

  const attempt = { id: draft.id, attempt_id: randomUUID() };
  for (const fault of ["missing", "corrupt"]) {
    c.check(
      `${fault}-master-refuses-verification`,
      (await faultManager(fault, c.a, "verify", attempt)).status === 503,
    );
    c.check(
      `${fault}-master-preserves-encrypted-enrollment`,
      await subscriptionFingerprint(draft.id) === original,
    );
    c.check(
      `${fault}-master-still-lists-metadata`,
      (await faultManager(fault, c.a, "list")).status === 200,
    );
    c.check(
      `${fault}-worker-needs-credential`,
      (await faultWorker(fault, c.anon)).status === 401,
    );
  }
  const deniedDraft = {
    ...draft,
    id: randomUUID(),
    name: "Unavailable creation",
  };
  c.check(
    "missing-master-refuses-new-enrollment",
    (await faultManager("missing", c.a, "create", deniedDraft)).status === 503,
  );
  c.check(
    "missing-master-creates-no-row",
    (await c.database(
      `select count(*)::int as n from taskfold_private.webhook_subscriptions where id='${deniedDraft.id}'`,
    ))[0].n === 0,
  );
  c.check(
    "missing-master-allows-discard",
    (await faultManager("missing", c.a, "cancel", { id: deniedDraft.id }))
      .status === 200,
  );

  const verified = await c.native(c.a, "verify", attempt);
  c.check(
    "original-master-recovers-same-verification",
    verified.status === 200 && verified.value.subscription.state === "active" &&
      verified.value.verification.attempt_id === attempt.attempt_id,
  );
  const recoveries = [];
  for (const fault of ["missing", "corrupt"]) {
    const user = fault === "missing" ? c.a : c.b;
    const tool = await c.keyFor(user);
    const h = fault === "missing"
      ? verified.value.subscription
      : await c.hook(user);
    const activeFingerprint = await subscriptionFingerprint(h.id);
    const encryptionFingerprint = async () =>
      (await c.database(
        `select md5(row(secret_hash,secret_envelope,created_at,expires_at)::text) as fingerprint from taskfold_private.webhook_subscriptions where id='${h.id}'`,
      ))[0].fingerprint;
    const originalEncryption = await encryptionFingerprint();
    const title = `Server ${fault} master recovery proof`;
    const task = await c.createTask(tool, { title });
    const before = await c.native(user, "history", { id: h.id });
    assert.equal(before.status, 200);
    const event = before.value.events.find((e) => e.status === "pending");
    assert(event, "New actual task event must be queued");
    const fingerprint = await eventFingerprint(event.id);
    const wireDigest = (await c.database(
      `select payload_sha256 as digest from taskfold_private.webhook_outbox where id='${event.id}'`,
    ))[0].digest;
    const failed = await faultWorker(fault);
    c.check(
      `${fault}-master-worker-defers-without-delivery`,
      failed.status === 200 && failed.value.failed === 1 &&
        failed.value.delivered === 0,
    );
    c.check(
      `${fault}-master-sends-no-task-content`,
      (await c.inspect(h)).length === 0,
    );
    const history = await c.native(user, "history", { id: h.id });
    assert.equal(history.status, 200);
    const row = history.value.events.find((e) => e.id === event.id);
    c.check(
      `${fault}-master-publishes-safe-deferral`,
      row?.status === "pending" && row.error === "configuration" &&
        history.value.subscription.delivery.blocked_reason ===
          "configuration" &&
        !JSON.stringify(history.value).includes(title),
    );
    c.check(
      `${fault}-master-defers-for-five-real-minutes`,
      Date.parse(row.next_attempt_at) >= Date.now() + 270000 &&
        Date.parse(row.next_attempt_at) <= Date.now() + 301000,
    );
    c.check(
      `${fault}-master-keeps-original-task-event`,
      await eventFingerprint(event.id) === fingerprint &&
        await subscriptionFingerprint(h.id) === activeFingerprint,
    );
    c.check(
      `${fault}-master-no-early-send-after-restoration`,
      (await c.send()).claimed === 0,
    );
    // Each scenario owns a different disposable account. Pause/resume also
    // verifies that ordinary controls preserve the event and its original due time.
    const paused =
      (await c.control(user, history.value.subscription, "pause")).h;
    recoveries.push({
      fault,
      user,
      wireDigest,
      h: paused,
      task,
      title,
      event,
      fingerprint,
      encryptionFingerprint,
      originalEncryption,
      due: Date.parse(row.next_attempt_at),
    });
  }
  for (const r of recoveries) {
    r.h = (await c.control(r.user, r.h, "resume")).h;
    c.check(
      `${r.fault}-master-control-retains-original-event`,
      await eventFingerprint(r.event.id) === r.fingerprint,
    );
  }
  c.check(
    "restored-service-keeps-real-backoff",
    (await c.send()).claimed === 0,
  );
  console.log("Waiting for the actual five-minute server recovery delay");
  const due = Math.max(...recoveries.map((r) => r.due)) + 500;
  while (Date.now() < due) {
    await new Promise((resolve) =>
      setTimeout(resolve, Math.min(10000, due - Date.now()))
    );
  }
  c.check(
    "restored-master-automatically-delivers-both-original-events",
    (await c.send()).delivered === 2,
  );
  for (const r of recoveries) {
    const messages = await c.inspect(r.h);
    const message = messages.find((m) =>
      JSON.parse(m.body).event_id === r.event.id
    );
    c.check(
      `${r.fault}-master-exact-signed-content-recovers`,
      messages.length === 1 && message?.attempts === 1 &&
        JSON.parse(message.body).task.id === r.task.id &&
        JSON.parse(message.body).task.title === r.title &&
        message.headers_safe === true &&
        createHash("sha256").update(message.body).digest("hex") ===
          r.wireDigest,
    );
    const complete = await c.native(r.user, "history", { id: r.h.id });
    c.check(
      `${r.fault}-master-history-confirms-delivery`,
      complete.status === 200 &&
        complete.value.events.find((e) => e.id === r.event.id)?.status ===
          "delivered",
    );
    c.check(
      `${r.fault}-master-recovery-never-rotates-encrypted-secret`,
      await r.encryptionFingerprint() === r.originalEncryption,
    );
    c.check(
      `${r.fault}-master-can-revoke-current-subscription`,
      (await faultManager("missing", r.user, "revoke", { id: r.h.id }))
        .status ===
        200,
    );
  }
  c.check(
    "no-duplicate-send-after-recovery",
    (await c.send()).claimed === 0 &&
      (await Promise.all(recoveries.map((r) => c.inspect(r.h)))).every(
        (messages) => messages.length === 1,
      ),
  );
  c.result.serviceRecovery = {
    actualHostedAuth: true,
    actualServerSessionExpiry: true,
    jwtClockExpiryClaimed: false,
    actualMissingAndWrongMasterConfigurations: true,
    faultsOnlyInTemporaryPreviewEntrypoints: true,
    actualCiphertextAndEventFingerprintChecks: true,
    actualAuthenticatedTLSReceiver: true,
    nativeUIAcceptanceClaimed: false,
    normalSecretCatalogNotRotatedForFaults: true,
    normalFeatureEnablementChanged: false,
  };
}
