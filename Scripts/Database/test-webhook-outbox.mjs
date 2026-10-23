import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import { loadWebhookOutboxSchema } from "./webhook-outbox-schema.mjs";
const output = process.argv[2],
  summary = {
    date: new Date().toISOString(),
    checks: {},
    realTasksChanged: 0,
    hostedAcceptance: false,
  };
const db = new PGlite({ extensions: { pgcrypto } });
const id = (n) => "f0a0cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const a = id(1),
  b = id(2),
  sa = id(11),
  sb = id(12),
  hook = id(21),
  task = id(31);
const value = async (sql, args = []) =>
  Object.values((await db.query(sql, args)).rows[0])[0];
const same = (name, actual, expected = true) => {
  assert.deepEqual(actual, expected, name);
  summary.checks[name] = true;
};
const manage = (action, body, owner = a, session = sa) =>
  value("select public.taskfold_webhooks($1,$2,$3,$4::jsonb)", [
    owner,
    session,
    action,
    JSON.stringify(body),
  ]);
const dispatch = (action, body = {}) =>
  value("select public.taskfold_webhook_dispatch($1,$2::jsonb)", [
    action,
    JSON.stringify(body),
  ]);
const settings = (target, extra = {}) => ({
  id: target,
  name: "Synthetic receiver",
  endpoint: "https://receiver.example/events",
  scope: "inbox",
  project_id: null,
  events: [
    "task.created",
    "task.updated",
    "task.completed",
    "task.reopened",
    "task.deleted",
  ],
  ttl_days: 30,
  secret_hash: "a".repeat(64),
  secret_envelope: {
    version: 1,
    keyVersion: "fixture-1",
    nonce: "A".repeat(16),
    ciphertext: "B".repeat(64),
  },
  ...extra,
});
async function mint(target = hook, extra = {}, owner = a, session = sa) {
  await manage("create", settings(target, extra), owner, session);
  await manage(
    "begin_verify",
    { id: target, attempt_id: id(sequence++) },
    owner,
    session,
  );
  const last = await value(
    "select attempt_id from taskfold_private.webhook_verifications where subscription_id=$1 order by created_at desc limit 1",
    [target],
  );
  await manage(
    "finish_verify",
    { id: target, attempt_id: last, outcome: "verified" },
    owner,
    session,
  );
}
let sequence = 1000;
const insert = (target, extra = {}) =>
  db.query(
    "insert into public.tasks(id,user_id,title,description,project_id) values($1,$2,$3,$4,$5)",
    [
      target,
      extra.user_id ?? a,
      extra.title ?? "Synthetic task",
      extra.description ?? "",
      extra.project_id ?? null,
    ],
  );
async function refuses(name, code, work) {
  let error;
  try {
    await work();
  } catch (e) {
    error = e;
  }
  same(name, error?.code, code);
}
async function next() {
  const claim = await dispatch("claim");
  if (!claim.event_id) return { claim };
  const ref = { event_id: claim.event_id, lease_id: claim.lease_id };
  return { claim, ref, packet: await dispatch("prepare", ref) };
}
async function deliver() {
  const row = await next();
  assert(row.packet?.ready, "Expected prepared packet");
  same("authorize-" + sequence++, (await dispatch("authorize", row.ref)).ready);
  await dispatch("ack", { ...row.ref, outcome: "delivered", status: 204 });
  return row;
}
try {
  await loadWebhookOutboxSchema((sql) => db.exec(sql));
  for (const [owner, session] of [[a, sa], [b, sb]]) {
    await db.query("insert into auth.users(id,email)values($1,$2)", [
      owner,
      owner + "@example.invalid",
    ]);
    await db.query("insert into public.profiles(user_id)values($1)", [owner]);
    await db.query("insert into auth.sessions(id,user_id)values($1,$2)", [
      session,
      owner,
    ]);
  }
  await insert(task);
  same(
    "no-events-before-a-verified-subscription",
    await value("select count(*)::int from taskfold_private.webhook_outbox"),
    0,
  );
  await manage("create", settings(hook));
  await insert(id(32));
  same(
    "pending-setup-never-captures-task-data",
    await value("select count(*)::int from taskfold_private.webhook_outbox"),
    0,
  );
  await mint(hook);
  await insert(id(33), { description: "Full synthetic note" });
  same(
    "committed-insert-captures-one-event",
    await value("select count(*)::int from taskfold_private.webhook_outbox"),
    1,
  );
  const sent = await deliver();
  same(
    "normal-event-keeps-the-logical-event-id",
    JSON.parse(sent.packet.body).event_id,
    sent.packet.part_id,
  );
  same(
    "normal-event-carries-full-note",
    JSON.parse(sent.packet.body).task.description,
    "Full synthetic note",
  );
  same(
    "delivered-body-is-erased",
    await value(
      "select payload is null from taskfold_private.webhook_outbox where id=$1",
      [sent.claim.event_id],
    ),
  );
  same(
    "delivery-frees-pending-and-retained-capacity",
    await value(
      "select pending=0 and retained_bytes=0 from taskfold_private.webhook_budgets where subscription_id=$1",
      [hook],
    ),
  );
  same(
    "late-ack-is-an-idempotent-noop",
    (await dispatch("ack", { ...sent.ref, outcome: "delivered", status: 204 }))
      .applied,
    false,
  );
  // UTF-8 is split into encoded byte parts, not JS characters. Receiver verifies
  // the whole immutable event checksum before parsing/releasing its snapshot.
  await insert(id(34), { description: "é📝".repeat(70000) });
  const chunks = [];
  let event, count, digest;
  for (let n = 0; n < 20; n++) {
    const row = await deliver(), frame = JSON.parse(row.packet.body);
    if (n === 0) {
      event = frame.event_id;
      count = frame.part_count;
      digest = frame.sha256;
    }
    same("multipart-envelope-" + n, frame.type, "taskfold.event.part");
    same("multipart-event-identity-" + n, frame.event_id, event);
    same(
      "multipart-http-bound-" + n,
      Buffer.byteLength(row.packet.body) <= 262144,
    );
    chunks[frame.part_index] = Buffer.from(frame.data, "base64");
    if (n + 1 === count) break;
  }
  const reassembled = Buffer.concat(chunks);
  same(
    "multipart-complete-checksum",
    createHash("sha256").update(reassembled).digest("hex"),
    digest,
  );
  same(
    "multipart-full-unicode-content-preserved",
    JSON.parse(reassembled).task.description,
    "é📝".repeat(70000),
  );
  same("multipart-left-no-open-work", (await dispatch("claim")).event_id, null);
  const rowCount = await value(
    "select count(*)::int from taskfold_private.webhook_outbox",
  );
  await db.exec(
    `begin;insert into public.tasks(id,user_id,title)values('${
      id(35)
    }','${a}','Rolled back');rollback;`,
  );
  same(
    "rollback-does-not-leave-events",
    await value("select count(*)::int from taskfold_private.webhook_outbox"),
    rowCount,
  );
  await db.query("update public.tasks set title='Edited source' where id=$1", [
    task,
  ]);
  const updated = await deliver();
  same(
    "actual-update-event",
    JSON.parse(updated.packet.body).type,
    "task.updated",
  );
  const afterEdit = await value(
    "select count(*)::int from taskfold_private.webhook_outbox",
  );
  await db.query(
    "update public.tasks set title=title,notification_sent_at=clock_timestamp() where id=$1",
    [task],
  );
  same(
    "no-op-and-internal-notification-markers-do-not-emit",
    await value("select count(*)::int from taskfold_private.webhook_outbox"),
    afterEdit,
  );
  await db.query("update public.tasks set completed=true where id=$1", [task]);
  const completion = [
    JSON.parse((await deliver()).packet.body).type,
    JSON.parse((await deliver()).packet.body).type,
  ].sort();
  same("completion-records-update-and-completion", completion, [
    "task.completed",
    "task.updated",
  ]);
  await db.query("update public.tasks set completed=false where id=$1", [task]);
  const reopened = [
    JSON.parse((await deliver()).packet.body).type,
    JSON.parse((await deliver()).packet.body).type,
  ].sort();
  same("reopening-records-update-and-reopen", reopened, [
    "task.reopened",
    "task.updated",
  ]);
  await db.query("update public.tasks set subtasks=$2::jsonb where id=$1", [
    task,
    JSON.stringify([{ id: id(901), title: "Nested proof", completed: true }]),
  ]);
  const child = JSON.parse((await deliver()).packet.body);
  same("nested-completion-remains-a-root-update", child.type, "task.updated");
  same("nested-snapshot-preserves-parent-state", child.task.completed, false);
  same("nested-snapshot-preserves-child", child.task.subtasks[0].completed);
  await db.query("delete from public.tasks where id=$1", [task]);
  const deleted = JSON.parse((await deliver()).packet.body);
  same(
    "deletion-is-generation-bound-minimal-data",
    Object.keys(deleted.task).sort(),
    ["id", "project_id", "task_generation"],
  );
  same("deletion-type", deleted.type, "task.deleted");
  const pause = await manage("pause", {
    id: hook,
    request_id: id(sequence++),
    revision: (await manage("details", { id: hook })).subscription.revision,
  });
  await insert(id(36));
  same(
    "paused-connection-retains-but-does-not-send",
    (await dispatch("claim")).event_id,
    null,
  );
  await manage("resume", {
    id: hook,
    request_id: id(sequence++),
    revision: pause.subscription.revision,
  });
  await deliver();
  await insert(id(37));
  let pending = await next();
  const firstBody = pending.packet.body;
  const version = (await manage("details", { id: hook })).subscription.revision;
  const pausedAgain = await manage("pause", {
    id: hook,
    request_id: id(sequence++),
    revision: version,
  });
  await manage("resume", {
    id: hook,
    request_id: id(sequence++),
    revision: pausedAgain.subscription.revision,
  });
  same(
    "late-authorizer-refuses-old-control-generation",
    (await dispatch("authorize", pending.ref)).ready,
    false,
  );
  pending = await next();
  same(
    "new-claim-keeps-immutable-body-after-controls",
    pending.packet.body,
    firstBody,
  );
  const beforeSend = await value(
    "select day_sends from taskfold_private.webhook_budgets where subscription_id=$1",
    [hook],
  );
  await dispatch("authorize", pending.ref);
  await dispatch("authorize", pending.ref);
  same(
    "authorization-retry-charges-once",
    await value(
      "select day_sends from taskfold_private.webhook_budgets where subscription_id=$1",
      [hook],
    ),
    beforeSend + 1,
  );
  await dispatch("ack", {
    ...pending.ref,
    outcome: "retry",
    status: 503,
    retry_after: 120,
  });
  same(
    "retry-after-defers-a-failed-send",
    (await dispatch("claim")).event_id,
    null,
  );
  await db.query(
    "update taskfold_private.webhook_outbox set next_attempt_at=clock_timestamp() where id=$1",
    [pending.ref.event_id],
  );
  const again = await next();
  same("retry-uses-same-part-id-and-body", [
    again.packet.part_id,
    again.packet.body,
  ], [pending.packet.part_id, pending.packet.body]);
  await dispatch("authorize", again.ref);
  await dispatch("ack", { ...again.ref, outcome: "gone", status: 410 });
  same(
    "gone-receiver-blocks-further-delivery",
    (await manage("details", { id: hook })).subscription.delivery
      .blocked_reason,
    "gone",
  );
  same(
    "failed-event-retains-body-for-explicit-retry",
    await value(
      "select payload is not null from taskfold_private.webhook_outbox where id=$1",
      [again.ref.event_id],
    ),
  );
  await manage("resume", {
    id: hook,
    request_id: id(sequence++),
    revision: (await manage("details", { id: hook })).subscription.revision,
  });
  const retryIntent = {
    id: hook,
    event_id: again.ref.event_id,
    request_id: id(sequence++),
  };
  await manage("retry_delivery", retryIntent);
  await deliver();
  const replay = await manage("retry_delivery", retryIntent);
  same(
    "late-manual-retry-receipt-does-not-resend",
    replay.event.status,
    "delivered",
  );
  same("manual-retry-counted-once", replay.event.manual_retries, 1);
  const history = await manage("history", { id: hook, limit: 2 });
  same("native-history-is-bounded", history.events.length, 2);
  same("history-has-cursor", typeof history.next_cursor, "string");
  same(
    "history-never-discloses-payload-or-secret",
    JSON.stringify(history).includes("Full synthetic note") ||
      JSON.stringify(history).includes("secret_envelope"),
    false,
  );
  await insert(id(38));
  pending = await next();
  await db.query(
    "update taskfold_private.webhook_outbox set lease_until=clock_timestamp()-interval '1 second' where id=$1",
    [pending.ref.event_id],
  );
  await db.query(
    "update taskfold_private.webhook_budgets set lease_until=clock_timestamp()-interval '1 second' where subscription_id=$1",
    [hook],
  );
  const recovered = await next();
  same(
    "expired-lease-is-recovered-with-new-identity",
    recovered.ref.lease_id !== pending.ref.lease_id,
  );
  same(
    "expired-lease-keeps-event-part-id",
    recovered.packet.part_id,
    pending.packet.part_id,
  );
  same(
    "old-worker-cannot-ack-the-new-lease",
    (await dispatch("ack", {
      ...pending.ref,
      outcome: "delivered",
      status: 204,
    })).applied,
    false,
  );
  await dispatch("authorize", recovered.ref);
  await dispatch("ack", {
    ...recovered.ref,
    outcome: "delivered",
    status: 204,
  });
  await insert(id(39));
  pending = await next();
  await db.query(
    "update taskfold_private.webhook_budgets set day_sends=1000 where subscription_id=$1",
    [hook],
  );
  same(
    "daily-network-budget-defers-without-sending",
    (await dispatch("authorize", pending.ref)).reason,
    "quota",
  );
  await db.query(
    "update taskfold_private.webhook_budgets set day_sends=0,window_sends=0 where subscription_id=$1",
    [hook],
  );
  await db.query(
    "update taskfold_private.webhook_outbox set next_attempt_at=clock_timestamp() where id=$1",
    [pending.ref.event_id],
  );
  await deliver();
  const countBeforeQuota = await value(
    "select count(*)::int from taskfold_private.webhook_outbox",
  );
  await db.query(
    "update taskfold_private.webhook_budgets set day_events=500 where subscription_id=$1",
    [hook],
  );
  await insert(id(40));
  same(
    "capture-quota-does-not-fail-task-save",
    await value("select count(*)::int from public.tasks where id=$1", [id(40)]),
    1,
  );
  same(
    "capture-quota-does-not-add-unbounded-rows",
    await value("select count(*)::int from taskfold_private.webhook_outbox"),
    countBeforeQuota,
  );
  same(
    "capture-quota-has-a-visible-warning",
    (await manage("details", { id: hook })).subscription.delivery.capture_issue,
    "event_quota",
  );
  await db.query(
    "update taskfold_private.webhook_budgets set day_events=0,pending=256 where subscription_id=$1",
    [hook],
  );
  await insert(id(41));
  same(
    "queue-capacity-has-a-visible-warning",
    (await manage("details", { id: hook })).subscription.delivery.capture_issue,
    "queue_capacity",
  );
  await db.query(
    "update taskfold_private.webhook_budgets set pending=0 where subscription_id=$1",
    [hook],
  );
  await insert(id(42), { description: "x".repeat(16777216) });
  same(
    "oversized-legacy-task-is-explicit-not-truncated",
    (await manage("details", { id: hook })).subscription.delivery.capture_issue,
    "payload_too_large",
  );
  await insert(id(43));
  pending = await next();
  await manage("revoke", { id: hook });
  same(
    "revocation-after-packet-refuses-final-authorization",
    (await dispatch("authorize", pending.ref)).ready,
    false,
  );
  same(
    "revoked-queue-erases-the-unsent-body",
    await value(
      "select payload is null from taskfold_private.webhook_outbox where id=$1",
      [pending.ref.event_id],
    ),
  );
  // Actual owner invitation -> recipient acceptance; foreign task authorship is
  // not a substitute for current project access.
  const project = id(201), privateProject = id(202), projectTask = id(203);
  await db.query(
    "insert into public.projects(id,user_id,name)values($1,$2,'Shared scope'),($3,$2,'Private scope')",
    [project, b, privateProject],
  );
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [b]);
  await db.query(
    "insert into public.project_collaborators(id,project_id,invited_by,invited_email,status)values($1,$2,$3,$4,'pending')",
    [id(204), project, b, a + "@example.invalid"],
  );
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [a]);
  await db.query(
    "update public.project_collaborators set status='accepted' where id=$1",
    [id(204)],
  );
  await mint(id(22), { scope: "all" });
  await mint(id(23), { scope: "project", project_id: project });
  await mint(id(24), { scope: "project", project_id: project }, b, sb);
  await insert(projectTask, {
    project_id: project,
    description: "Readable shared note",
  });
  same(
    "project-change-fans-out-to-real-readable-scopes",
    await value(
      "select count(*)::int from taskfold_private.webhook_outbox where task_id=$1",
      [projectTask],
    ),
    3,
  );
  let removed = false, cancelled = 0, ownerMessages = 0;
  for (let n = 0; n < 3; n++) {
    const row = await next();
    if (row.packet.ready && row.packet.account === b) {
      same(
        "owner-authorize-" + n,
        (await dispatch("authorize", row.ref)).ready,
      );
      await dispatch("ack", { ...row.ref, outcome: "delivered", status: 204 });
      ownerMessages++;
    } else if (row.packet.ready) {
      if (!removed) {
        await db.query(
          "update public.project_collaborators set status='pending' where id=$1",
          [id(204)],
        );
        removed = true;
      }
      same(
        "access-removed-after-preparation-blocks-write",
        (await dispatch("authorize", row.ref)).reason,
        "resource_unavailable",
      );
      cancelled++;
    } else {
      same(
        "other-lost-scope-cancels-before-packet",
        row.packet.reason,
        "resource_unavailable",
      );
      cancelled++;
    }
  }
  same("actual-project-owner-still-receives", ownerMessages, 1);
  same("both-former-member-scopes-cancel", cancelled, 2);
  await db.query(
    "update public.project_collaborators set status='accepted' where id=$1",
    [id(204)],
  );
  await db.query(
    "update public.tasks set project_id=$2,title='New private title' where id=$1",
    [projectTask, privateProject],
  );
  for (let n = 0; n < 3; n++) {
    const removal = JSON.parse((await deliver()).packet.body);
    same("scope-exit-is-minimal-" + n, removal.type, "task.removed");
    same(
      "scope-exit-hides-new-private-location-" + n,
      JSON.stringify(removal).includes(privateProject) ||
        JSON.stringify(removal).includes("New private title"),
      false,
    );
  }
  await manage("revoke", { id: id(22) });
  await manage("revoke", { id: id(23) });
  await mint(id(25));
  // Clock fixtures are newly inserted owned rows; production timestamp/history
  // guards remain enabled throughout expiration and retention checks.
  async function clockEvent(target, finished = false) {
    const body = JSON.stringify({
        version: 1,
        event_id: target,
        type: "task.deleted",
        occurred_at: "2026-10-01T00:00:00Z",
        task: { id: id(890), task_generation: id(891), project_id: null },
      }),
      bytes = Buffer.byteLength(body),
      digest = createHash("sha256").update(body).digest("hex");
    await db.query(
      "insert into taskfold_private.webhook_outbox(id,user_id,subscription_id,task_id,task_generation,access_owner,event_type,minimal,payload,payload_bytes,payload_sha256,part_count,next_part,status,created_at,expires_at,next_attempt_at,finished_at)values($1,$2,$3,$4,$5,$2,'task.deleted',true,$6,$7,$8,1,$9,$10,clock_timestamp()-interval '9 days',clock_timestamp()-interval '8 days',clock_timestamp()-interval '9 days',case when $11 then clock_timestamp()-interval '8 days' else null end)",
      [
        target,
        a,
        id(25),
        id(890),
        id(891),
        finished ? null : body,
        bytes,
        digest,
        finished ? 1 : 0,
        finished ? "delivered" : "pending",
        finished,
      ],
    );
    if (!finished) {
      await db.query(
        "update taskfold_private.webhook_budgets set pending=pending+1,retained_bytes=retained_bytes+$2 where subscription_id=$1",
        [id(25), bytes],
      );
    }
  }
  await clockEvent(id(892));
  await dispatch("sweep");
  same(
    "expired-event-is-erased-and-recorded",
    await value(
      "select status='expired' and payload is null from taskfold_private.webhook_outbox where id=$1",
      [id(892)],
    ),
  );
  same(
    "expiry-frees-capacity",
    await value(
      "select pending=0 and retained_bytes=0 from taskfold_private.webhook_budgets where subscription_id=$1",
      [id(25)],
    ),
  );
  await clockEvent(id(893), true);
  await db.query(
    "insert into taskfold_private.webhook_retry_receipts(user_id,request_id,event_id)values($1,$2,$3)",
    [a, id(894), id(893)],
  );
  await dispatch("sweep");
  same(
    "seven-day-history-prunes-with-retry-receipts",
    await value(
      "select ((select count(*) from taskfold_private.webhook_outbox where id=$1)+(select count(*) from taskfold_private.webhook_retry_receipts where event_id=$1))::int",
      [id(893)],
    ),
    0,
  );
  await insert(id(895));
  let exhausted;
  for (let cycle = 0; cycle < 4; cycle++) {
    for (let n = 0; n < 12; n++) {
      const trial = await next();
      same(
        "attempt-authorized-" + cycle + "-" + n,
        (await dispatch("authorize", trial.ref)).ready,
      );
      await dispatch("ack", { ...trial.ref, outcome: "retry", status: 503 });
      exhausted = trial.ref.event_id;
      if (n < 11) {
        await db.query(
          "update taskfold_private.webhook_outbox set next_attempt_at=clock_timestamp() where id=$1",
          [exhausted],
        );
      }
    }
    same(
      "twelve-attempt-budget-is-terminal-" + cycle,
      await value(
        "select status from taskfold_private.webhook_outbox where id=$1",
        [exhausted],
      ),
      "failed",
    );
    if (cycle < 3) {
      await manage("retry_delivery", {
        id: id(25),
        event_id: exhausted,
        request_id: id(900 + cycle),
      });
    }
  }
  await refuses(
    "manual-retry-is-bounded-to-three",
    "PT409",
    () =>
      manage("retry_delivery", {
        id: id(25),
        event_id: exhausted,
        request_id: id(903),
      }),
  );
  await manage("revoke", { id: id(25) });
  await dispatch("sweep");
  same(
    "revoking-connection-cleans-failed-payload",
    await value(
      "select payload is null and status='cancelled' from taskfold_private.webhook_outbox where id=$1",
      [exhausted],
    ),
  );
  await refuses("clients-cannot-read-queue-bodies", "42501", async () => {
    await db.exec("set role authenticated");
    try {
      await value("select count(*) from taskfold_private.webhook_outbox");
    } finally {
      await db.exec("reset role");
    }
  });
  await db.query("delete from auth.users where id=$1", [a]);
  same(
    "auth-deletion-cascades-all-queue-private-data",
    await value(
      "select ((select count(*) from taskfold_private.webhook_outbox where user_id=$1)+(select count(*) from taskfold_private.webhook_budgets where user_id=$1)+(select count(*) from taskfold_private.webhook_retry_receipts where user_id=$1))::int",
      [a],
    ),
    0,
  );
  await refuses("native-user-cannot-call-worker", "42501", async () => {
    await db.exec("set role authenticated");
    try {
      await dispatch("claim");
    } finally {
      await db.exec("reset role");
    }
  });
  summary.passed = true;
} catch (error) {
  summary.passed = false;
  summary.failure = { message: error.message, code: error.code };
  process.exitCode = 1;
} finally {
  await db.close();
  if (output) await writeFile(output, JSON.stringify(summary, null, 2) + "\n");
  console.log(JSON.stringify(summary));
}
