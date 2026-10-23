import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import { loadEmailIntakeSchema } from "./email-intake-schema.mjs";
const db = new PGlite({ extensions: { pgcrypto } }), output = process.argv[2];
const summary = {
  date: new Date().toISOString(),
  checks: {},
  deployed: false,
  realDataChanged: false,
};
const id = (n) => "f0e1cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const a = id(1),
  b = id(2),
  unverified = id(3),
  sa = id(11),
  sb = id(12),
  su = id(13),
  project = id(31),
  member = id(32);
const hash = (n) =>
  createHash("sha256").update("synthetic-alias-" + n).digest("hex");
const q = async (sql, args = []) => (await db.query(sql, args)).rows;
const value = async (sql, args = []) =>
  Object.values((await q(sql, args))[0])[0];
const same = (name, actual, expected = true) => {
  summary.checks[name] = false;
  assert.deepEqual(actual, expected, name);
  summary.checks[name] = true;
};
const manage = (action, body = {}, owner = a, session = sa) =>
  value("select public.taskfold_email_routes($1,$2,$3,$4::jsonb)", [
    owner,
    session,
    action,
    JSON.stringify(body),
  ]);
const stamp = new Date().toISOString();
const receivedByDelivery = new Map();
const draft = (n, extra = {}) => ({
  id: id(n),
  name: "Synthetic inbox " + n,
  alias_hash: hash(n),
  project_id: null,
  requested_at: stamp,
  ...extra,
});
const content = {
  title: 'Résumé 📝 "Review"',
  description: "First\n  second\tline \\ path العربية",
  attachmentCount: 0,
};
const deliver = (n = 21, receipt = "receipt_1", extra = {}) => {
  const args = {
    alias: hash(n),
    provider: "synthetic-adapter",
    receipt,
    received: receivedByDelivery.get(n + ":" + receipt) ??
      new Date().toISOString(),
    sender: "intake-a@example.invalid",
    content,
    ...extra,
  };
  if (!receivedByDelivery.has(n + ":" + receipt)) {
    receivedByDelivery.set(n + ":" + receipt, args.received);
  }
  return value(
    "select public.taskfold_email_deliver($1,$2,$3,$4,$5,$6::jsonb)",
    [
      args.alias,
      args.provider,
      args.receipt,
      args.received,
      args.sender,
      JSON.stringify(args.content),
    ],
  );
};
async function refuses(name, code, work) {
  let found;
  try {
    await work();
  } catch (e) {
    found = e.code;
  }
  same(name, found, code);
}
try {
  await loadEmailIntakeSchema((sql) => db.exec(sql));
  await q(
    "insert into auth.users(id,email,email_confirmed_at) values($1,'intake-a@example.invalid',now()),($2,'intake-b@example.invalid',now()),($3,'unverified@example.invalid',null)",
    [a, b, unverified],
  );
  await q(
    "insert into auth.sessions(id,user_id) values($1,$2),($3,$4),($5,$6)",
    [sa, a, sb, b, su, unverified],
  );
  await q("insert into public.profiles(user_id) values($1),($2),($3)", [
    a,
    b,
    unverified,
  ]);
  same("default delivery gate closed", (await manage("list")).available, false);
  await refuses(
    "disabled create refused",
    "PT503",
    () => manage("create", draft(21)),
  );
  same(
    "disabled create stores no route",
    await value("select count(*)::int from taskfold_private.email_routes"),
    0,
  );
  await db.exec(
    "update taskfold_private.email_intake_config set enabled=true,provider='synthetic-adapter'",
  );
  await refuses(
    "unknown session refused",
    "28000",
    () => manage("list", {}, a, sb),
  );
  await refuses(
    "unverified sender cannot set up capture",
    "42501",
    () => manage("create", draft(23), unverified, su),
  );
  for (
    const [name, body] of [
      ["unknown field", { ...draft(21), senderVerified: true }],
      ["invalid identity", draft(21, { id: "../other" })],
      ["invalid name", draft(21, { name: "bad\nname" })],
      ["invalid project", draft(21, { project_id: "other" })],
      ["bad timestamp", draft(21, { requested_at: "2026-02-31T00:00:00Z" })],
      ["old setup", draft(21, { requested_at: "2020-01-01T00:00:00Z" })],
    ]
  ) await refuses(name + " refused", "22023", () => manage("create", body));
  const minted = await manage("create", draft(21));
  same(
    "verified sender fixed by Auth",
    minted.route.sender_email,
    "intake-a@example.invalid",
  );
  same(
    "route receipt omits alias hash",
    JSON.stringify(minted).includes(hash(21)),
    false,
  );
  same(
    "same setup retry keeps complete receipt",
    await manage("create", draft(21)),
    minted,
  );
  await refuses(
    "changed setup conflicts",
    "PT409",
    () => manage("create", draft(21, { name: "Changed" })),
  );
  await refuses(
    "foreign route identity refused",
    "PT404",
    () => manage("create", draft(21), b, sb),
  );
  await refuses(
    "foreign route edits refused",
    "PT404",
    () => manage("pause", { id: id(21), revision: 1 }, b, sb),
  );
  same("foreign catalog empty", (await manage("list", {}, b, sb)).routes, []);
  await refuses(
    "untrusted sender refused",
    "42501",
    () => deliver(21, "receipt_1", { sender: "stranger@example.invalid" }),
  );
  await refuses(
    "plus alias not guessed to be same sender",
    "42501",
    () =>
      deliver(21, "receipt_1", { sender: "intake-a+other@example.invalid" }),
  );
  await refuses(
    "wrong configured provider refused",
    "PT503",
    () => deliver(21, "receipt_1", { provider: "other-provider" }),
  );
  await refuses("unknown route refused", "PT404", () => deliver(99));
  for (
    const [name, body] of [
      ["extra destination", { ...content, project_id: project }],
      ["extra sender claim", { ...content, senderVerified: true }],
      ["header newline", { ...content, title: "hello\nBcc" }],
      ["binary content", { ...content, description: "bad\u0001" }],
      ["not normalized CR", { ...content, description: "a\rb" }],
      ["large UTF8 title", { ...content, title: "é".repeat(257) }],
      ["invalid count", { ...content, attachmentCount: 0.5 }],
    ]
  ) {
    await refuses(
      name + " refused",
      "22023",
      () => deliver(21, "bad-payload", { content: body }),
    );
  }
  same(
    "rejected input creates no tasks",
    await value("select count(*)::int from public.tasks"),
    0,
  );
  same(
    "rejected input creates no journal",
    await value("select count(*)::int from taskfold_private.email_deliveries"),
    0,
  );
  await value("select set_config('request.jwt.claim.sub',$1,false)", [b]);
  same("first delivery committed", await deliver(), {
    accepted: true,
    replayed: false,
  });
  same(
    "actor claim restored",
    await value("select current_setting('request.jwt.claim.sub')"),
    b,
  );
  const first = (await q("select * from public.tasks"))[0],
    receipt = (await q("select * from taskfold_private.email_deliveries"))[0];
  same("owner comes from route", first.user_id, a);
  same("Inbox remains Inbox", first.project_id, null);
  same("title preserved", first.title, content.title);
  same("full note preserved", first.description, content.description);
  same("no instruction-derived planning", [
    first.priority,
    first.due_date,
    first.assigned_to,
    first.completed,
  ], [4, null, null, false]);
  same(
    "generation identity recorded",
    receipt.task_generation,
    first.task_generation,
  );
  same("no private metadata leaks to task", first.source_metadata, {});
  same(
    "content fingerprint matches JS contract",
    receipt.content_fingerprint,
    createHash("sha256").update(
      JSON.stringify([
        "taskfold-email-content",
        1,
        content.title,
        content.description,
        0,
      ]),
    ).digest("hex"),
  );
  same(
    "delivery key matches JS contract",
    receipt.delivery_key,
    createHash("sha256").update(
      JSON.stringify([
        "taskfold-email-delivery",
        1,
        "synthetic-adapter",
        "receipt_1",
        id(21),
      ]),
    ).digest("hex"),
  );
  same("exact retry acknowledged", await deliver(), {
    accepted: true,
    replayed: true,
  });
  same(
    "exact retry cannot duplicate task",
    await value("select count(*)::int from public.tasks"),
    1,
  );
  await refuses(
    "changed content cannot overwrite task",
    "PT409",
    () =>
      deliver(21, "receipt_1", {
        content: { ...content, description: "Changed" },
      }),
  );
  await refuses(
    "changed original timestamp conflicts",
    "PT409",
    () =>
      deliver(21, "receipt_1", {
        received: new Date(
          Date.parse(receivedByDelivery.get("21:receipt_1")) - 1000,
        ).toISOString(),
      }),
  );
  await q("update public.tasks set title='User edited note' where id=$1", [
    first.id,
  ]);
  await deliver();
  same(
    "retry preserves user edit",
    await value("select title from public.tasks where id=$1", [first.id]),
    "User edited note",
  );
  await q(
    "insert into public.projects(id,user_id,name) values($1,$2,'User move destination')",
    [id(33), a],
  );
  await q("update public.tasks set project_id=$1 where id=$2", [
    id(33),
    first.id,
  ]);
  await deliver();
  same(
    "retry preserves user task move",
    await value("select project_id from public.tasks where id=$1", [first.id]),
    id(33),
  );
  await q("delete from public.tasks where id=$1", [first.id]);
  await deliver();
  same(
    "retry never recreates deleted task",
    await value("select count(*)::int from public.tasks"),
    0,
  );
  const restoredGeneration = await value("select gen_random_uuid()");
  await q(
    "insert into public.tasks(id,user_id,title,task_generation) values($1,$2,'User restored task',$3)",
    [first.id, a, restoredGeneration],
  );
  await deliver();
  same(
    "retry preserves restored incarnation",
    await value(
      "select jsonb_build_array(title,task_generation) from public.tasks where id=$1",
      [first.id],
    ),
    ["User restored task", restoredGeneration],
  );
  same(
    "email receipt retains original generation",
    await value(
      "select task_generation from taskfold_private.email_deliveries where route_id=$1",
      [id(21)],
    ),
    first.task_generation,
  );
  await q("delete from public.tasks where id=$1", [first.id]);
  await q(
    "update taskfold_private.email_routes set created_at=now()-interval '2 hours',requested_at=now()-interval '2 hours',accept_after=now()-interval '2 hours' where id=$1",
    [id(21)],
  );
  const pausedMailTime = new Date(Date.now() - 3600000).toISOString();
  await manage("pause", { id: id(21), revision: 1 });
  same(
    "pause replay does not increment revision",
    (await manage("pause", { id: id(21), revision: 1 })).route.revision,
    2,
  );
  await refuses(
    "paused delivery refused even for replay",
    "PT404",
    () => deliver(),
  );
  await manage("resume", { id: id(21), revision: 2 });
  await refuses(
    "resume cannot import mail from paused interval",
    "22023",
    () => deliver(21, "arrived-while-paused", { received: pausedMailTime }),
  );
  same(
    "already committed retry still acknowledged after resume",
    (await deliver()).replayed,
    true,
  );
  await refuses(
    "stale pause cannot undo resume",
    "PT409",
    () => manage("pause", { id: id(21), revision: 1 }),
  );
  await q(
    "insert into public.projects(id,user_id,name) values($1,$2,'Shared destination')",
    [project, b],
  );
  await value("select set_config('request.jwt.claim.sub',$1,false)", [b]);
  await q(
    "insert into public.project_collaborators(id,project_id,invited_by,invited_email,status) values($1,$2,$3,'intake-a@example.invalid','pending')",
    [member, project, b],
  );
  await value("select set_config('request.jwt.claim.sub',$1,false)", [a]);
  await q(
    "update public.project_collaborators set status='accepted' where id=$1",
    [member],
  );
  await manage("create", draft(22, { project_id: project }));
  await deliver(22, "shared_1");
  same(
    "accepted shared destination used",
    await value("select project_id from public.tasks"),
    project,
  );
  await q("delete from public.project_collaborators where id=$1", [member]);
  await refuses(
    "lost membership refuses new mail",
    "PT404",
    () => deliver(22, "shared_2"),
  );
  await refuses(
    "lost membership refuses old receipt access",
    "PT404",
    () => deliver(22, "shared_1"),
  );
  same(
    "lost membership cannot fall back to Inbox",
    await value(
      "select count(*)::int from public.tasks where project_id is null",
    ),
    0,
  );
  await q(
    "update public.projects set user_id=$1,is_archived=true where id=$2",
    [a, project],
  );
  await refuses(
    "archived project refuses delivery",
    "PT409",
    () => deliver(22, "shared_2"),
  );
  await q(
    "update public.projects set is_archived=false,ancestor_archived=true where id=$1",
    [project],
  );
  await refuses(
    "archived ancestor refuses delivery",
    "PT409",
    () => deliver(22, "shared_2"),
  );
  await q("delete from public.projects where id=$1", [project]);
  same(
    "deleted route destination is retained",
    await value(
      "select project_id from taskfold_private.email_routes where id=$1",
      [id(22)],
    ),
    project,
  );
  await refuses(
    "deleted project refuses delivery",
    "PT404",
    () => deliver(22, "shared_2"),
  );
  const rotation = { id: id(21), revision: 3, replacement: draft(24) };
  const rotated = await manage("rotate", rotation);
  same("rotation revokes old address", rotated.replaced.state, "revoked");
  same("replacement active", rotated.route.state, "active");
  same(
    "rotation retry retains replacement",
    await manage("rotate", rotation),
    rotated,
  );
  await refuses(
    "old address rejected after rotation",
    "PT404",
    () => deliver(),
  );
  await refuses(
    "old setup replay cannot revive address",
    "PT404",
    () => deliver(21, "receipt_1"),
  );
  await refuses(
    "revoked route cannot resume",
    "PT409",
    () => manage("resume", { id: id(21), revision: 4 }),
  );
  await manage("revoke", { id: id(25), revision: 0 });
  await refuses(
    "cancel before create fences late enrollment",
    "PT409",
    () => manage("create", draft(25)),
  );
  await refuses(
    "failed rotation rolls back old revocation",
    "22023",
    () =>
      manage("rotate", {
        id: id(24),
        revision: 1,
        replacement: draft(26, { requested_at: "2020-01-01T00:00:00Z" }),
      }),
  );
  same(
    "old route survives failed rotation",
    (await manage("list")).routes.find((r) => r.id === id(24)).state,
    "active",
  );
  await q(
    "update auth.users set email='new-owner@example.invalid' where id=$1",
    [a],
  );
  await refuses(
    "changed Auth email invalidates old sender approval",
    "42501",
    () => deliver(24, "new_1"),
  );
  await q(
    "update auth.users set email='intake-a@example.invalid',email_confirmed_at=null where id=$1",
    [a],
  );
  await refuses(
    "removed verification refuses old routes",
    "42501",
    () => deliver(24, "new_1"),
  );
  await q("update auth.users set email_confirmed_at=now() where id=$1", [a]);
  await q(
    "update auth.sessions set not_after=now()-interval '1 second' where id=$1",
    [sa],
  );
  await refuses(
    "expired native session refuses management",
    "28000",
    () => manage("list"),
  );
  await q("update auth.sessions set not_after=null where id=$1", [sa]);
  await q(
    "insert into taskfold_private.account_removal_receipts(token_hash,account_id) values($1,$2)",
    [hash(900), a],
  );
  await refuses(
    "pending account removal blocks delivery",
    "28000",
    () => deliver(24, "new_1"),
  );
  await refuses(
    "pending account removal blocks management",
    "28000",
    () => manage("list"),
  );
  await q(
    "delete from taskfold_private.account_removal_receipts where account_id=$1",
    [a],
  );
  await q(
    "update auth.users set banned_until=now()+interval '1 day' where id=$1",
    [a],
  );
  await refuses(
    "banned account cannot receive",
    "28000",
    () => deliver(24, "new_1"),
  );
  await q("update auth.users set banned_until=null where id=$1", [a]);
  await refuses(
    "stale original delivery refused",
    "22023",
    () => deliver(24, "stale", { received: "2020-01-01T00:00:00Z" }),
  );
  await refuses(
    "future original delivery refused",
    "22023",
    () => deliver(24, "future", { received: "2100-01-01T00:00:00Z" }),
  );
  await deliver(24, "retention_1");
  await db.exec(
    "update taskfold_private.email_deliveries set created_at=clock_timestamp()-interval '31 days',received_at=clock_timestamp()-interval '31 days'",
  );
  await value("select public.taskfold_email_prune($1)", [a]);
  same(
    "expired delivery tombstones pruned",
    await value("select count(*)::int from taskfold_private.email_deliveries"),
    0,
  );
  await refuses(
    "pruned receipt cannot replay old message",
    "22023",
    () =>
      deliver(24, "retention_1", {
        received: new Date(Date.now() - 31 * 86400000).toISOString(),
      }),
  );
  // Route admission and atomic replacement at the live-address limit.
  for (const n of [51, 52, 53]) await manage("create", draft(n));
  same(
    "five live routes available",
    (await manage("list")).routes.filter((r) => r.state !== "revoked").length,
    5,
  );
  await refuses(
    "sixth live route refused",
    "PT429",
    () => manage("create", draft(54)),
  );
  const atCapacity = await manage("rotate", {
    id: id(53),
    revision: 1,
    replacement: draft(55),
  });
  same(
    "rotation works at live route capacity",
    atCapacity.route.state,
    "active",
  );
  same(
    "rotation retains live route limit",
    (await manage("list")).routes.filter((r) => r.state !== "revoked").length,
    5,
  );
  for (const n of [51, 52, 55]) {
    await manage("revoke", { id: id(n), revision: 1 });
  }
  for (const n of [56, 57, 58]) {
    await manage("create", draft(n));
    await manage("revoke", { id: id(n), revision: 1 });
  }
  await refuses(
    "rolling route birth limit enforced",
    "PT429",
    () => manage("create", draft(59)),
  );
  await manage("create", draft(41), b, sb);
  await deliver(41, "b_first", { sender: "intake-b@example.invalid" });
  // Quotas include durable tombstones from deleted tasks and do not charge retries.
  await q(
    "insert into taskfold_private.email_deliveries(route_id,user_id,delivery_key,content_fingerprint,received_at,task_id,task_generation) select $1,$2,md5(n::text)||md5(('quota-'||n)::text),repeat('a',64),now(),gen_random_uuid(),gen_random_uuid() from generate_series(1,49)n",
    [id(41), b],
  );
  await refuses(
    "fiftieth route-hour final slot enforced",
    "PT429",
    () => deliver(41, "over_hour", { sender: "intake-b@example.invalid" }),
  );
  same(
    "exact receipt retry works at quota",
    await deliver(41, "b_first", { sender: "intake-b@example.invalid" }),
    { accepted: true, replayed: true },
  );
  await db.exec(
    "update taskfold_private.email_deliveries set created_at=now()-interval '2 hours'",
  );
  await manage("create", draft(42), b, sb);
  await q(
    "insert into taskfold_private.email_deliveries(route_id,user_id,delivery_key,content_fingerprint,received_at,task_id,task_generation,created_at) select $1,$2,md5(('daily-'||n)::text)||md5(n::text),repeat('b',64),now(),gen_random_uuid(),gen_random_uuid(),now()-interval '2 hours' from generate_series(1,50)n",
    [id(42), b],
  );
  await refuses(
    "account daily quota spans routes",
    "PT429",
    () => deliver(41, "over_day", { sender: "intake-b@example.invalid" }),
  );
  await db.exec(
    "update taskfold_private.email_deliveries set created_at=now()-interval '2 days'",
  );
  same(
    "rolling quota permits a later day",
    (await deliver(41, "later_day", { sender: "intake-b@example.invalid" }))
      .accepted,
    true,
  );
  same(
    "256-byte receipt identity supported",
    (await deliver(41, "x".repeat(256), { sender: "intake-b@example.invalid" }))
      .accepted,
    true,
  );
  await refuses(
    "257-byte receipt identity refused",
    "22023",
    () => deliver(41, "x".repeat(257), { sender: "intake-b@example.invalid" }),
  );
  await refuses(
    "non-ASCII receipt identity refused",
    "22023",
    () => deliver(41, "réceipt", { sender: "intake-b@example.invalid" }),
  );
  same(
    "Unicode content contract remains compatible",
    (await deliver(41, "unicode", {
      sender: "intake-b@example.invalid",
      content: {
        ...content,
        description: "Unicode separator \u0085 and العربية",
      },
    })).accepted,
    true,
  );
  await q(
    "insert into taskfold_private.email_deliveries(route_id,user_id,delivery_key,content_fingerprint,received_at,task_id,task_generation,created_at) select $1,$2,md5(('storage-'||n)::text)||md5(n::text),repeat('c',64),now()-interval '2 days',gen_random_uuid(),gen_random_uuid(),now()-interval '2 days' from generate_series(1,6000-(select count(*)::int from taskfold_private.email_deliveries where user_id=$2))n",
    [id(42), b],
  );
  await refuses(
    "hard receipt storage bound enforced",
    "PT429",
    () => deliver(41, "over_storage", { sender: "intake-b@example.invalid" }),
  );
  const ownedB = await value(
    "select count(*)::int from public.tasks where user_id=$1",
    [b],
  );
  await q("delete from auth.users where id=$1", [a]);
  same(
    "account deletion clears routes",
    await value(
      "select count(*)::int from taskfold_private.email_routes where user_id=$1",
      [a],
    ),
    0,
  );
  same(
    "account deletion clears receipts",
    await value(
      "select count(*)::int from taskfold_private.email_deliveries where user_id=$1",
      [a],
    ),
    0,
  );
  same(
    "account deletion clears cancellations",
    await value(
      "select count(*)::int from taskfold_private.email_route_cancellations where user_id=$1",
      [a],
    ),
    0,
  );
  same(
    "other account tasks retained",
    await value("select count(*)::int from public.tasks where user_id=$1", [b]),
    ownedB,
  );
  await refuses(
    "removed account cannot receive late mail",
    "PT404",
    () => deliver(24, "late"),
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    for (
      const table of [
        "email_routes",
        "email_route_cancellations",
        "email_deliveries",
        "email_intake_config",
      ]
    ) {
      same(
        role + " has no direct " + table + " access",
        await value(
          "select has_table_privilege($1,$2,'SELECT,INSERT,UPDATE,DELETE')",
          [role, "taskfold_private." + table],
        ),
        false,
      );
    }
  }
  same(
    "all intake tables use RLS",
    await value(
      "select bool_and(relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='taskfold_private' and c.relname like 'email_%' and c.relkind='r'",
    ),
    true,
  );
  same(
    "public wrappers are invokers",
    await value(
      "select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'taskfold_email_%' and p.prosecdef",
    ),
    0,
  );
  for (const role of ["anon", "authenticated"]) {
    same(
      role + " cannot execute intake RPC",
      await value(
        "select has_function_privilege($1,'public.taskfold_email_deliver(text,text,text,timestamptz,text,jsonb)','EXECUTE')",
        [role],
      ),
      false,
    );
  }
  await db.exec("set role authenticated");
  await refuses(
    "actual native SQL execution refused",
    "42501",
    () => manage("list", {}, b, sb),
  );
  await db.exec("reset role");
  summary.passed = true;
} catch (error) {
  summary.passed = false;
  summary.failure = {
    message: error.message,
    code: error.code,
    where: error.where,
  };
  process.exitCode = 1;
} finally {
  await db.close();
  if (output) await writeFile(output, JSON.stringify(summary, null, 2) + "\n");
  console.log(JSON.stringify(summary));
}
