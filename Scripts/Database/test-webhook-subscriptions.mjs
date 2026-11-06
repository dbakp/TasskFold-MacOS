import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import { loadAutomationPostgresSchema } from "./automation-postgres-schema.mjs";
const output = process.argv[2];
const summary = {
  date: new Date().toISOString(),
  checks: {},
  realTasksChanged: 0,
  hostedAcceptance: false,
};
const db = new PGlite({ extensions: { pgcrypto } });
const id = (n) => "f09dcafe-0000-4000-8000-" + String(n).padStart(12, "0");
const a = id(1),
  b = id(2),
  c = id(3),
  sa = id(11),
  sb = id(12),
  sc = id(13),
  project = id(21);
const value = async (sql, args = []) =>
  Object.values((await db.query(sql, args)).rows[0])[0];
const same = (name, actual, expected = true) => {
  assert.deepEqual(actual, expected, name);
  summary.checks[name] = true;
};
let commandSequence = 3000;
async function manage(action, body, account = a, session = sa) {
  if (
    ["pause", "resume"].includes(action) && !Object.hasOwn(body, "request_id")
  ) {
    const current = await manage("details", { id: body.id }, account, session);
    body = {
      ...body,
      request_id: id(commandSequence++),
      revision: current.subscription.revision,
    };
  }
  return await value("select public.taskfold_webhooks($1,$2,$3,$4::jsonb)", [
    account,
    session,
    action,
    JSON.stringify(body),
  ]);
}
const envelope = {
  version: 1,
  keyVersion: "fixture-1",
  nonce: "A".repeat(16),
  ciphertext: "B".repeat(64),
};
const settings = (target, extra = {}) => ({
  id: target,
  name: "Synthetic receiver",
  endpoint: "https://receiver.example/events?token=private-fixture",
  scope: "inbox",
  project_id: null,
  events: ["task.created", "task.completed"],
  ttl_days: 30,
  secret_hash: "a".repeat(64),
  secret_envelope: envelope,
  ...extra,
});
async function refuses(name, code, work) {
  let failure;
  try {
    await work();
  } catch (e) {
    failure = e;
  }
  same(name, failure?.code, code);
}
try {
  await loadAutomationPostgresSchema((sql) => db.exec(sql));
  await db.exec(
    await readFile(
      new URL(
        "../../supabase/migrations/20261023050732_webhook_subscriptions.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  for (const [owner, session] of [[a, sa], [b, sb], [c, sc]]) {
    await db.query("insert into auth.users(id,email) values($1,$2);", [
      owner,
      owner + "@example.invalid",
    ]);
    await db.query(
      "insert into auth.sessions(id,user_id,not_after) values($1,$2,clock_timestamp()+interval '1 day')",
      [session, owner],
    );
    await db.query("insert into public.profiles(user_id) values($1)", [owner]);
  }
  await db.query(
    "insert into public.projects(id,user_id,name) values($1,$2,'Private project')",
    [project, b],
  );
  await db.exec("set role service_role");
  const issued = await manage("create", settings(id(101)));
  same(
    "verified-service-can-create-pending-only",
    issued.subscription.state,
    "pending",
  );
  same(
    "receipt-redacts-query-path-and-key",
    issued.subscription.origin,
    "https://receiver.example",
  );
  same(
    "no-secret-envelope-in-receipt",
    JSON.stringify(issued).includes("ciphertext"),
    false,
  );
  same(
    "no-secret-hash-in-receipt",
    JSON.stringify(issued).includes("secret_hash"),
    false,
  );
  same(
    "retry-does-not-renew-expiry",
    (await manage(
      "create",
      settings(id(101), {
        secret_envelope: { ...envelope, nonce: "C".repeat(16) },
      }),
    )).subscription.expires_at,
    issued.subscription.expires_at,
  );
  same(
    "same-endpoint-intent-has-one-record",
    (await manage("list", {})).subscriptions.length,
    1,
  );
  same(
    "foreign-account-sees-no-subscriptions",
    (await manage("list", {}, b, sb)).subscriptions.length,
    0,
  );
  await refuses(
    "foreign-account-cannot-read-details",
    "PT404",
    () => manage("details", { id: id(101) }, b, sb),
  );
  await refuses(
    "foreign-account-cannot-use-same-id",
    "PT404",
    () => manage("create", settings(id(101)), b, sb),
  );
  await refuses(
    "changed-create-intent-refused",
    "PT409",
    () => manage("create", settings(id(101), { events: ["task.updated"] })),
  );
  await refuses(
    "unsigned-session-has-no-management",
    "28000",
    () => manage("list", {}, a, sb),
  );
  await refuses(
    "wrong-project-permission-refused",
    "PT404",
    () =>
      manage(
        "create",
        settings(id(102), { scope: "project", project_id: project }),
      ),
  );
  for (
    const [name, extra] of [
      ["duplicate-events", { events: ["task.created", "task.created"] }],
      ["unknown-events", { events: ["task.magic"] }],
      ["missing-project", { scope: "project" }],
      ["null-name", { name: null }],
      ["invalid-envelope", { secret_envelope: {} }],
      ["userinfo", { endpoint: "https://user:pass@receiver.example/" }],
      ["bad-TTL", { ttl_days: 7 }],
    ]
  ) {
    await refuses(
      "reject-" + name,
      "22023",
      () => manage("create", settings(id(109), extra)),
    );
  }
  await refuses(
    "cannot-pause-unverified-endpoint",
    "PT409",
    () => manage("pause", { id: id(101) }),
  );
  const begun = await manage("begin_verify", {
    id: id(101),
    attempt_id: id(201),
  });
  same(
    "challenge-is-random-256-bit-nonce",
    /^[a-f0-9]{64}$/.test(begun.challenge.nonce),
  );
  same(
    "challenge-gets-original-encrypted-secret",
    begun.secret_envelope,
    envelope,
  );
  const again = await manage("begin_verify", {
    id: id(101),
    attempt_id: id(201),
  });
  same(
    "exact-retry-keeps-challenge-and-expiry",
    again.challenge,
    begun.challenge,
  );
  same(
    "verification-retry-does-not-create-record",
    again.verification,
    begun.verification,
  );
  const failed = await manage("finish_verify", {
    id: id(101),
    attempt_id: id(201),
    outcome: "refused",
  });
  same(
    "failed-proof-keeps-endpoint-pending",
    failed.subscription.state,
    "pending",
  );
  same(
    "late-success-does-not-overwrite-first-terminal-result",
    (await manage("finish_verify", {
      id: id(101),
      attempt_id: id(201),
      outcome: "verified",
    })).verification.outcome,
    "refused",
  );
  await manage("begin_verify", { id: id(101), attempt_id: id(202) });
  const verified = await manage("finish_verify", {
    id: id(101),
    attempt_id: id(202),
    outcome: "verified",
  });
  same(
    "trusted-validated-proof-connects-endpoint",
    verified.subscription.state,
    "active",
  );
  same(
    "proof-acknowledgement-retry-is-stable",
    await manage("finish_verify", {
      id: id(101),
      attempt_id: id(202),
      outcome: "verified",
    }),
    verified,
  );
  same(
    "pause-is-durable",
    (await manage("pause", { id: id(101) })).subscription.state,
    "paused",
  );
  same(
    "resume-requires-verified-record",
    (await manage("resume", { id: id(101) })).subscription.state,
    "active",
  );
  const baseline =
    (await manage("details", { id: id(101) })).subscription.revision;
  const pauseIntent = { id: id(101), request_id: id(3200), revision: baseline };
  const paused = await manage("pause", pauseIntent);
  same(
    "pause-advances-state-revision",
    paused.subscription.revision !== baseline,
  );
  const resumed = await manage("resume", {
    id: id(101),
    request_id: id(3201),
    revision: paused.subscription.revision,
  });
  same(
    "late-pause-retry-cannot-undo-newer-resume",
    (await manage("pause", pauseIntent)).subscription.state,
    "active",
  );
  same(
    "exact-command-retry-confirms-same-request",
    (await manage("pause", pauseIntent)).command,
    { request_id: id(3200), applied: true },
  );
  await refuses(
    "stale-new-pause-needs-review",
    "PT409",
    () => manage("pause", { ...pauseIntent, request_id: id(3202) }),
  );
  await refuses(
    "same-command-id-cannot-change-action",
    "PT409",
    () => manage("resume", pauseIntent),
  );
  same(
    "stale-command-did-not-change-current-revision",
    (await manage("details", { id: id(101) })).subscription.revision,
    resumed.subscription.revision,
  );
  const revoked = await manage("revoke", { id: id(101) });
  same("revoke-records-terminal-state", revoked.subscription.state, "revoked");
  same(
    "revoke-retry-keeps-timestamp",
    (await manage("revoke", { id: id(101) })).subscription.revoked_at,
    revoked.subscription.revoked_at,
  );
  same(
    "late-create-never-reactivates-revoked-endpoint",
    (await manage("create", settings(id(101)))).subscription.state,
    "revoked",
  );
  await refuses(
    "revoked-endpoint-cannot-resume",
    "PT409",
    () => manage("resume", { id: id(101) }),
  );
  same(
    "ordinary-list-excludes-revoked",
    (await manage("list", {})).subscriptions.length,
    0,
  );
  same(
    "history-retains-revoked",
    (await manage("list", { include_inactive: true })).subscriptions.length,
    1,
  );
  same(
    "details-explicitly-return-private-destination",
    (await manage("details", { id: id(101) })).endpoint,
    settings(id(101)).endpoint,
  );
  await manage("cancel", { id: id(103) });
  same("cancel-retry-is-idempotent", await manage("cancel", { id: id(103) }), {
    account: a,
    id: id(103),
    cancelled: true,
  });
  await refuses(
    "cancel-before-create-permanently-blocks-late-create",
    "PT409",
    () => manage("create", settings(id(103))),
  );
  await manage("cancel", { id: id(101) }, b, sb);
  same(
    "foreign-cancel-does-not-expose-or-change-owner",
    (await manage("details", { id: id(101) })).subscription.state,
    "revoked",
  );
  await manage("create", settings(id(104)));
  await manage("begin_verify", { id: id(104), attempt_id: id(203) });
  await manage("begin_verify", { id: id(104), attempt_id: id(204) });
  same(
    "new-attempt-invalidates-older-callback",
    (await manage("finish_verify", {
      id: id(104),
      attempt_id: id(203),
      outcome: "verified",
    })).verification.outcome,
    "cancelled",
  );
  await manage("cancel", { id: id(104) });
  same(
    "discard-during-proof-cannot-connect-later",
    (await manage("finish_verify", {
      id: id(104),
      attempt_id: id(204),
      outcome: "verified",
    })).subscription.state,
    "revoked",
  );
  await db.exec("reset role");
  same(
    "revocation-erases-retrievable-receiver-secret",
    await value(
      "select secret_envelope is null from taskfold_private.webhook_subscriptions where id=$1",
      [id(101)],
    ),
  );
  await db.query(
    "update taskfold_private.webhook_verifications set created_at=clock_timestamp()-interval '1 hour' where user_id=$1",
    [a],
  );
  await manage("create", settings(id(105)));
  await manage("begin_verify", { id: id(105), attempt_id: id(205) });
  await db.query(
    "update taskfold_private.webhook_verifications set expires_at=clock_timestamp()-interval '1 second' where attempt_id=$1",
    [id(205)],
  );
  same(
    "expired-proof-does-not-connect",
    (await manage("finish_verify", {
      id: id(105),
      attempt_id: id(205),
      outcome: "verified",
    })).verification.outcome,
    "expired",
  );
  await manage("revoke", { id: id(105) });
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [b]);
  await db.query(
    "insert into public.project_collaborators(id,project_id,user_id,invited_by,status,invited_email) values($1,$2,$3,$4,'pending',$5)",
    [id(31), project, a, b, a + "@example.invalid"],
  );
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [a]);
  await db.query(
    "update public.project_collaborators set status='accepted' where id=$1",
    [id(31)],
  );
  await manage(
    "create",
    settings(id(106), { scope: "project", project_id: project }),
  );
  await manage("begin_verify", { id: id(106), attempt_id: id(206) });
  await db.query(
    "update public.project_collaborators set status='pending' where id=$1",
    [id(31)],
  );
  await refuses(
    "membership-loss-during-proof-prevents-activation",
    "PT404",
    () =>
      manage("finish_verify", {
        id: id(106),
        attempt_id: id(206),
        outcome: "verified",
      }),
  );
  same(
    "revocation-still-works-after-project-access-loss",
    (await manage("revoke", { id: id(106) })).subscription.state,
    "revoked",
  );
  await manage("create", settings(id(107)), c, sc);
  await manage("begin_verify", { id: id(107), attempt_id: id(207) }, c, sc);
  await db.query("delete from auth.sessions where id=$1", [sc]);
  await refuses(
    "signout-during-proof-prevents-activation",
    "28000",
    () =>
      manage(
        "finish_verify",
        { id: id(107), attempt_id: id(207), outcome: "verified" },
        c,
        sc,
      ),
  );
  await db.query("insert into auth.sessions(id,user_id) values($1,$2)", [
    sc,
    c,
  ]);
  // Starting account removal must disconnect before Auth cleanup succeeds.
  await db.query(
    "insert into taskfold_private.account_removal_receipts(account_id,token_hash) values($1,$2)",
    [c, "a".repeat(64)],
  );
  same(
    "removal-revokes-before-auth-delete",
    await value(
      "select state from taskfold_private.webhook_subscriptions where id=$1",
      [id(107)],
    ),
    "revoked",
  );
  await refuses(
    "removing-account-cannot-manage",
    "28000",
    () => manage("list", {}, c, sc),
  );
  await db.query("delete from auth.users where id=$1", [c]);
  same(
    "auth-delete-cleans-subscriptions-and-attempts",
    await value(
      "select ((select count(*) from taskfold_private.webhook_subscriptions where user_id=$1)+(select count(*) from taskfold_private.webhook_verifications where user_id=$1))::int",
      [c],
    ),
    0,
  );
  const page = await manage("list", { include_inactive: true, limit: 1 });
  same(
    "bounded-page-has-owned-cursor",
    page.subscriptions.length === 1 &&
      page.next_cursor === page.subscriptions[0].id,
  );
  const second = await manage("list", {
    include_inactive: true,
    limit: 1,
    cursor: page.next_cursor,
  });
  same(
    "next-page-does-not-repeat-first",
    second.subscriptions[0].id !== page.subscriptions[0].id,
  );
  await refuses(
    "foreign-cursor-does-not-disclose-history",
    "22023",
    () => manage("list", { cursor: page.next_cursor }, b, sb),
  );
  for (let n = 301; n <= 305; n++) await manage("create", settings(id(n)));
  await refuses(
    "five-live-subscription-limit",
    "PT429",
    () => manage("create", settings(id(306))),
  );
  await manage("cancel", { id: id(301) }, b, sb);
  same(
    "foreign-discard-does-not-revoke-pending-owner",
    (await manage("details", { id: id(301) })).subscription.state,
    "pending",
  );
  for (let n = 301; n <= 305; n++) await manage("revoke", { id: id(n) });
  await manage("create", settings(id(306)));
  await manage("revoke", { id: id(306) });
  await refuses(
    "ten-creation-per-day-limit-includes-revoked",
    "PT429",
    () => manage("create", settings(id(307))),
  );
  await manage("create", settings(id(501)), b, sb);
  for (let n = 601; n <= 606; n++) {
    await manage("begin_verify", { id: id(501), attempt_id: id(n) }, b, sb);
  }
  await refuses(
    "six-new-verifications-per-minute",
    "PT429",
    () => manage("begin_verify", { id: id(501), attempt_id: id(607) }, b, sb),
  );
  same(
    "exact-verification-retry-is-free-at-limit",
    (await manage("begin_verify", { id: id(501), attempt_id: id(606) }, b, sb))
      .verification.outcome,
    "pending",
  );
  await db.query(
    "update taskfold_private.webhook_verifications set created_at=date_trunc('day',clock_timestamp() at time zone 'UTC') at time zone 'UTC' where user_id=$1",
    [b],
  );
  for (let n = 701; n <= 754; n++) {
    await db.query(
      "insert into taskfold_private.webhook_verifications(user_id,attempt_id,subscription_id,nonce,created_at,expires_at,outcome,finished_at) values($1,$2,$3,$4,date_trunc('day',clock_timestamp() at time zone 'UTC') at time zone 'UTC',clock_timestamp(),'cancelled',clock_timestamp())",
      [b, id(n), id(501), "a".repeat(64)],
    );
  }
  await refuses(
    "sixty-new-verifications-per-day",
    "PT429",
    () => manage("begin_verify", { id: id(501), attempt_id: id(608) }, b, sb),
  );
  await manage(
    "finish_verify",
    { id: id(501), attempt_id: id(606), outcome: "verified" },
    b,
    sb,
  );
  const controlBaseline =
    (await manage("details", { id: id(501) }, b, sb)).subscription.revision;
  for (let n = 4001; n <= 4200; n++) {
    await db.query(
      "insert into taskfold_private.webhook_commands(user_id,request_id,subscription_id,action,baseline,result_revision) values($1,$2,$3,'pause',$4,$4)",
      [b, id(n), id(501), controlBaseline],
    );
  }
  await refuses(
    "new-control-receipts-are-bounded-per-day",
    "PT429",
    () =>
      manage(
        "pause",
        { id: id(501), request_id: id(4201), revision: controlBaseline },
        b,
        sb,
      ),
  );
  same(
    "revoke-remains-available-at-verification-limit",
    (await manage("revoke", { id: id(501) }, b, sb)).subscription.state,
    "revoked",
  );
  for (let n = 1001; n <= 1099; n++) {
    await db.query(
      "insert into taskfold_private.webhook_cancellations(user_id,id) values($1,$2)",
      [a, id(n)],
    );
  }
  await refuses(
    "new-cancellation-tombstones-are-bounded",
    "PT429",
    () => manage("cancel", { id: id(1100) }),
  );
  same(
    "existing-discard-retries-work-at-limit",
    (await manage("cancel", { id: id(103) })).cancelled,
  );
  same(
    "revoking-existing-setup-works-at-cancellation-limit",
    (await manage("cancel", { id: id(101) })).cancelled,
  );
  await refuses(
    "command-history-cannot-be-rewritten",
    "PT409",
    () =>
      db.query(
        "update taskfold_private.webhook_commands set action='resume' where user_id=$1 and request_id=$2",
        [a, id(3200)],
      ),
  );
  await refuses(
    "command-history-cannot-be-pruned",
    "PT409",
    () =>
      db.query(
        "delete from taskfold_private.webhook_commands where user_id=$1",
        [a],
      ),
  );
  await refuses(
    "cancellation-history-cannot-be-pruned",
    "PT409",
    () =>
      db.query(
        "delete from taskfold_private.webhook_cancellations where user_id=$1",
        [a],
      ),
  );
  await refuses(
    "revoked-setup-history-cannot-be-pruned",
    "PT409",
    () =>
      db.query(
        "delete from taskfold_private.webhook_subscriptions where id=$1",
        [id(101)],
      ),
  );
  await refuses(
    "revoked-setup-cannot-be-renewed",
    "PT409",
    () =>
      db.query(
        "update taskfold_private.webhook_subscriptions set expires_at=clock_timestamp()+interval '2 years' where id=$1",
        [id(101)],
      ),
  );
  for (const role of ["anon", "authenticated"]) {
    await db.exec("set role " + role);
    await refuses(
      role + "-cannot-call-management",
      "42501",
      () => manage("list", {}),
    );
    await refuses(
      role + "-cannot-read-encrypted-table",
      "42501",
      () =>
        value("select count(*) from taskfold_private.webhook_subscriptions"),
    );
    await db.exec("reset role");
  }
  await db.exec("set role service_role");
  await refuses(
    "service-has-no-direct-table-access",
    "42501",
    () => value("select count(*) from taskfold_private.webhook_subscriptions"),
  );
  await db.exec("reset role");
  same(
    "all-private-tables-enable-RLS",
    await value(
      "select bool_and(relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='taskfold_private' and c.relname in('webhook_subscriptions','webhook_cancellations','webhook_verifications','webhook_commands','webhook_removal_blocks')",
    ),
  );
  same(
    "no-webhook-task-trigger-is-installed",
    await value(
      "select count(*)::int from pg_trigger where tgrelid='public.tasks'::regclass and tgname like '%webhook%'",
    ),
    0,
  );
  await db.query("delete from auth.users where id=$1", [a]);
  same(
    "physical-auth-removal-cleans-immutable-history",
    await value(
      "select ((select count(*) from taskfold_private.webhook_subscriptions where user_id=$1)+(select count(*) from taskfold_private.webhook_commands where user_id=$1)+(select count(*) from taskfold_private.webhook_cancellations where user_id=$1))::int",
      [a],
    ),
    0,
  );
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
