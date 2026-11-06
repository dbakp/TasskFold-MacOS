// Real PostgreSQL 17.6 sessions, explicit lock barriers, synthetic accounts only.
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import {
  createPostgresFixture,
  literal as lit,
  postgresImage,
} from "./postgres-fixture.mjs";
import { loadAutomationPostgresSchema } from "./automation-postgres-schema.mjs";
const output = process.argv[2],
  summary = {
    date: new Date().toISOString(),
    image: postgresImage,
    checks: {},
    barriers: [],
    realTasksChanged: 0,
    hostedAcceptance: false,
    containerRemoved: false,
  };
let pg;
const id = (n) => "f09fcafe-0000-4000-8000-" + String(n).padStart(12, "0");
const a = id(1),
  b = id(2),
  sa = id(11),
  sb = id(12),
  project = id(21),
  member = id(31);
const same = (name, actual, expected = true) => {
  assert.deepEqual(actual, expected, name);
  summary.checks[name] = true;
};
const doc = (value) => lit(JSON.stringify(value)) + "::jsonb";
const expression = (action, body, owner = a, session = sa) =>
  `public.taskfold_webhooks(${lit(owner)},${lit(session)},${lit(action)},${
    doc(body)
  })`;
const accountLock = (owner) =>
  `select pg_advisory_xact_lock(hashtextextended('automation:${owner}',11819))`;
const settings = (target, extra = {}) => ({
  id: target,
  name: "Synthetic receiver",
  endpoint: "https://receiver.example/events",
  scope: "inbox",
  project_id: null,
  events: ["task.created"],
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
const scalar = (sql) => pg.scalar("select to_jsonb((" + sql + "))");
const call = (action, body, options = {}) =>
  pg.value(
    expression(action, body, options.owner ?? a, options.session ?? sa),
    { app: options.app ?? "taskfold-webhook-worker" },
  );
async function setup(target, attempt, extra = {}) {
  same(
    "create-" + target,
    (await call("create", settings(target, extra))).code,
    null,
  );
  same(
    "begin-" + attempt,
    (await call("begin_verify", { id: target, attempt_id: attempt })).code,
    null,
  );
}
async function wait(app, holder) {
  const barrier = await pg.waitForLock(app, holder.pid);
  summary.barriers.push({ app, ...barrier });
}
try {
  pg = await createPostgresFixture();
  summary.postgresVersion = pg.serverVersion;
  await loadAutomationPostgresSchema((sql) => pg.raw(sql));
  await pg.raw(
    await readFile(
      new URL(
        "../../supabase/migrations/20261023050732_webhook_subscriptions.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  await pg.raw(
    `insert into auth.users(id,email) values(${
      lit(a)
    },'webhook-a@example.invalid'),(${
      lit(b)
    },'webhook-b@example.invalid');insert into public.profiles(user_id) values(${
      lit(a)
    }),(${lit(b)});insert into auth.sessions(id,user_id) values(${lit(sa)},${
      lit(a)
    }),(${lit(sb)},${
      lit(b)
    });insert into public.projects(id,user_id,name) values(${lit(project)},${
      lit(b)
    },'Synthetic shared project');`,
  );
  // One enrollment, independent transactions and a known advisory-lock barrier.
  let holder = await pg.hold(accountLock(a));
  const retries = Array.from(
    { length: 8 },
    (_, i) =>
      call("create", settings(id(101)), { app: "taskfold-webhook-retry-" + i }),
  );
  await wait("taskfold-webhook-retry-0", holder);
  await holder.release("commit");
  const enrolled = await Promise.all(retries);
  same(
    "eight-exact-enrollments-have-one-receipt",
    new Set(enrolled.map((r) => JSON.stringify(r.value))).size,
    1,
  );
  same("all-exact-enrollments-succeed", enrolled.every((r) => r.code === null));
  same(
    "enrollments-use-independent-backends",
    new Set(enrolled.map((r) => r.pid)).size >= 2,
  );
  same(
    "one-row-after-concurrent-retries",
    await scalar(
      "select count(*)::int from taskfold_private.webhook_subscriptions where id=" +
        lit(id(101)),
    ),
    1,
  );
  const conflicts = await Promise.all([
    call("create", settings(id(102))),
    call("create", settings(id(102), { name: "Different settings" })),
  ]);
  same(
    "different-intents-with-one-id-have-one-conflict",
    conflicts.map((r) => r.code).sort(),
    [null, "PT409"].sort(),
  );
  await call("revoke", { id: id(101) });
  await call("revoke", { id: id(102) });
  holder = await pg.hold(accountLock(b));
  const slots = Array.from(
    { length: 12 },
    (_, i) =>
      call("create", settings(id(201 + i)), {
        owner: b,
        session: sb,
        app: "taskfold-webhook-slot-" + i,
      }),
  );
  await wait("taskfold-webhook-slot-0", holder);
  await holder.release("commit");
  const results = await Promise.all(slots);
  same(
    "five-final-slots-are-atomic",
    results.filter((r) => r.code === null).length,
    5,
  );
  same(
    "other-seven-enrollments-refused",
    results.filter((r) => r.code === "PT429").length,
    7,
  );
  same(
    "no-quota-overrun-in-table",
    await scalar(
      "select count(*)::int from taskfold_private.webhook_subscriptions where user_id=" +
        lit(b),
    ),
    5,
  );
  // Revocation wins before the already validated network result is recorded.
  await setup(id(103), id(303));
  holder = await pg.hold(`select ${expression("revoke", { id: id(103) })}`);
  const late = call("finish_verify", {
    id: id(103),
    attempt_id: id(303),
    outcome: "verified",
  }, { app: "taskfold-webhook-revoke-first" });
  await wait("taskfold-webhook-revoke-first", holder);
  await holder.release("commit");
  const refusedLate = await late;
  same(
    "late-proof-does-not-reactivate-revoked-endpoint",
    refusedLate.value.subscription.state,
    "revoked",
  );
  same(
    "late-proof-is-cancelled",
    refusedLate.value.verification.outcome,
    "cancelled",
  );
  same(
    "revoked-secret-remains-erased",
    await scalar(
      "select secret_envelope is null from taskfold_private.webhook_subscriptions where id=" +
        lit(id(103)),
    ),
  );
  await setup(id(104), id(304));
  holder = await pg.hold(
    `select ${
      expression("finish_verify", {
        id: id(104),
        attempt_id: id(304),
        outcome: "verified",
      })
    }`,
  );
  const revokeAfter = call("revoke", { id: id(104) }, {
    app: "taskfold-webhook-proof-first",
  });
  await wait("taskfold-webhook-proof-first", holder);
  await holder.release("commit");
  same(
    "proof-first-then-revoke-is-still-terminal",
    (await revokeAfter).value.subscription.state,
    "revoked",
  );
  same(
    "successful-verification-does-not-protect-secret-from-revoke",
    await scalar(
      "select secret_envelope is null from taskfold_private.webhook_subscriptions where id=" +
        lit(id(104)),
    ),
  );
  await setup(id(105), id(305));
  holder = await pg.hold(`delete from auth.sessions where id=${lit(sa)}`);
  const signedOut = call("finish_verify", {
    id: id(105),
    attempt_id: id(305),
    outcome: "verified",
  }, { app: "taskfold-webhook-session" });
  await wait("taskfold-webhook-session", holder);
  await holder.release("commit");
  same("committed-signout-blocks-late-proof", (await signedOut).code, "28000");
  same(
    "signout-left-no-activation",
    await scalar(
      "select state from taskfold_private.webhook_subscriptions where id=" +
        lit(id(105)),
    ),
    "pending",
  );
  await pg.raw(
    `insert into auth.sessions(id,user_id) values(${lit(sa)},${lit(a)})`,
  );
  await call("revoke", { id: id(105) });
  await setup(id(106), id(306));
  await pg.raw(
    `update taskfold_private.webhook_verifications set expires_at=clock_timestamp()+interval '200 milliseconds' where attempt_id=${
      lit(id(306))
    }`,
  );
  holder = await pg.hold(accountLock(a));
  const expired = call("finish_verify", {
    id: id(106),
    attempt_id: id(306),
    outcome: "verified",
  }, { app: "taskfold-webhook-expiry" });
  await wait("taskfold-webhook-expiry", holder);
  await new Promise((r) => setTimeout(r, 250));
  await holder.release("commit");
  same(
    "expiry-is-rechecked-after-the-lock-wait",
    (await expired).value.verification.outcome,
    "expired",
  );
  await call("revoke", { id: id(106) });
  await pg.raw(
    `select set_config('request.jwt.claim.sub',${
      lit(b)
    },false);insert into public.project_collaborators(id,project_id,invited_by,invited_email,status) values(${
      lit(member)
    },${lit(project)},${
      lit(b)
    },'webhook-a@example.invalid','pending');select set_config('request.jwt.claim.sub',${
      lit(a)
    },false);update public.project_collaborators set status='accepted' where id=${
      lit(member)
    };`,
  );
  await setup(id(107), id(307), { scope: "project", project_id: project });
  holder = await pg.hold(
    `select set_config('request.jwt.claim.sub',${
      lit(a)
    },false);update public.project_collaborators set status='pending' where id=${
      lit(member)
    }`,
  );
  const removedMember = call("finish_verify", {
    id: id(107),
    attempt_id: id(307),
    outcome: "verified",
  }, { app: "taskfold-webhook-member" });
  await wait("taskfold-webhook-member", holder);
  await holder.release("commit");
  same(
    "membership-removal-wins-before-proof-commit",
    (await removedMember).code,
    "PT404",
  );
  same(
    "membership-removal-left-no-activation",
    await scalar(
      "select state from taskfold_private.webhook_subscriptions where id=" +
        lit(id(107)),
    ),
    "pending",
  );
  await call("revoke", { id: id(107) });
  // Reset only the synthetic test's attempt times, separating this identity race
  // from the already tested per-minute verification issuance budget.
  await pg.raw(
    `update taskfold_private.webhook_verifications set created_at=clock_timestamp()-interval '10 minutes' where user_id=${
      lit(a)
    }`,
  );
  await setup(id(109), id(309));
  const connected = await call("finish_verify", {
    id: id(109),
    attempt_id: id(309),
    outcome: "verified",
  });
  const pauseIntent = {
    id: id(109),
    request_id: id(4002),
    revision: connected.value.subscription.revision,
  };
  const pause = await call("pause", pauseIntent);
  same("guarded-pause-succeeds", pause.code, null);
  const resume = await call("resume", {
    id: id(109),
    request_id: id(4003),
    revision: pause.value.subscription.revision,
  });
  same("newer-resume-succeeds", resume.value.subscription.state, "active");
  same(
    "late-old-pause-retry-does-not-reapply",
    (await call("pause", pauseIntent)).value.subscription.state,
    "active",
  );
  same(
    "new-stale-pause-needs-current-review",
    (await call("pause", { ...pauseIntent, request_id: id(4004) })).code,
    "PT409",
  );
  same(
    "same-control-id-cannot-change-action",
    (await call("resume", pauseIntent)).code,
    "PT409",
  );
  same(
    "exact-control-retry-does-not-add-a-receipt",
    await scalar(
      "select count(*)::int from taskfold_private.webhook_commands where subscription_id=" +
        lit(id(109)),
    ),
    2,
  );
  await setup(id(108), id(308));
  const removalBaseline = await scalar(
    "select revision from taskfold_private.webhook_subscriptions where id=" +
      lit(id(108)),
  );
  holder = await pg.hold(
    `select public.taskfold_account_removal_begin(${lit(a)},${lit(sa)},${
      lit("b".repeat(64))
    })`,
  );
  const removing = call("finish_verify", {
    id: id(108),
    attempt_id: id(308),
    outcome: "verified",
  }, { app: "taskfold-webhook-removal" });
  await wait("taskfold-webhook-removal", holder);
  await holder.release("commit");
  same("removal-receipt-blocks-late-proof", (await removing).code, "28000");
  same(
    "removal-permanently-revokes-and-erases-secret",
    await scalar(
      "select state='revoked' and secret_envelope is null from taskfold_private.webhook_subscriptions where id=" +
        lit(id(108)),
    ),
  );
  await pg.raw(
    `delete from taskfold_private.account_removal_receipts where account_id=${
      lit(a)
    }`,
  );
  same(
    "receipt-pruning-cannot-restore-account-access",
    (await call("resume", {
      id: id(108),
      request_id: id(4001),
      revision: removalBaseline,
    })).code,
    "28000",
  );
  same(
    "receipt-pruning-cannot-enroll-a-new-webhook",
    (await call("create", settings(id(110)))).code,
    "28000",
  );
  let markerRefusal;
  try {
    await pg.raw(
      "delete from taskfold_private.webhook_removal_blocks where user_id=" +
        lit(a),
    );
  } catch (error) {
    markerRefusal = error.code;
  }
  same("permanent-removal-marker-cannot-be-pruned", markerRefusal, "PT409");
  summary.passed = true;
} catch (error) {
  summary.passed = false;
  summary.failure = { message: error.message, code: error.code };
  process.exitCode = 1;
} finally {
  if (pg) summary.containerRemoved = await pg.close();
  if (output) await writeFile(output, JSON.stringify(summary, null, 2) + "\n");
  console.log(JSON.stringify(summary));
}
