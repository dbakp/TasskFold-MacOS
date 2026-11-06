import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import {
  emailDomainMigration,
  loadEmailIntakeSchema,
} from "./email-intake-schema.mjs";
const db = new PGlite({ extensions: { pgcrypto } });
const summary = {
  date: new Date().toISOString(),
  checks: {},
  deployed: false,
  realDataChanged: false,
};
const id = (n) => "f0e3cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const owner = id(1),
  session = id(11),
  a = "mail.example.invalid",
  b = "capture.example.invalid";
const q = async (sql, args = []) => (await db.query(sql, args)).rows;
const value = async (sql, args = []) =>
  Object.values((await q(sql, args))[0])[0];
const same = (label, actual, expected = true) => {
  summary.checks[label] = false;
  assert.deepEqual(actual, expected, label);
  summary.checks[label] = true;
};
const refuse = async (label, code, work) => {
  let found;
  try {
    await work();
  } catch (e) {
    found = e.code;
  }
  same(label, found, code);
};
const manage = (action, body = {}) =>
  value("select public.taskfold_email_routes($1,$2,$3,$4::jsonb)", [
    owner,
    session,
    action,
    JSON.stringify(body),
  ]);
const configure = (
  provider = "synthetic-adapter",
  domain = a,
  enabled = true,
) =>
  value("select public.taskfold_email_configure($1,$2,$3)", [
    provider,
    domain,
    enabled,
  ]);
const stamp = new Date().toISOString();
const setup = (n, domain = a) => ({
  id: id(n),
  name: "Synthetic domain " + n,
  alias_hash: createHash("sha256").update("synthetic-domain-" + n).digest(
    "hex",
  ),
  project_id: null,
  requested_at: stamp,
  ...domain ? { domain } : {},
});
let boundDelivery = false;
const deliver = (n, domain = a) => {
  const args = [
    setup(n, domain).alias_hash,
    "receipt-" + n,
    new Date().toISOString(),
    JSON.stringify({
      title: "Synthetic original mail",
      description: "Keep the complete note",
      attachmentCount: 0,
    }),
  ];
  if (boundDelivery) args.push(domain);
  return value(
    boundDelivery
      ? "select public.taskfold_email_deliver_v2($1,$5,'synthetic-adapter',$2,$3,'domain-owner@example.invalid',$4::jsonb)"
      : "select public.taskfold_email_deliver($1,'synthetic-adapter',$2,$3,'domain-owner@example.invalid',$4::jsonb)",
    args,
  );
};

try {
  await loadEmailIntakeSchema((sql) => db.exec(sql), { domainBinding: false });
  await q(
    "insert into auth.users(id,email,email_confirmed_at) values($1,'domain-owner@example.invalid',now())",
    [owner],
  );
  await q("insert into auth.sessions(id,user_id) values($1,$2)", [
    session,
    owner,
  ]);
  await q("insert into public.profiles(user_id) values($1)", [owner]);
  await db.exec(
    "update taskfold_private.email_intake_config set enabled=true,provider='synthetic-adapter'",
  );
  for (const n of [21, 22, 23, 24]) await manage("create", setup(n, null));
  await manage("pause", { id: id(22), revision: 1 });
  await manage("revoke", { id: id(23), revision: 1 });
  await q(
    "update taskfold_private.email_routes set revision=2147483647 where id=$1",
    [id(24)],
  );
  await deliver(21);
  const before = await value(
    "select jsonb_build_object('tasks',(select jsonb_agg(to_jsonb(t) order by id) from public.tasks t),'receipts',(select jsonb_agg(to_jsonb(d) order by route_id) from taskfold_private.email_deliveries d))",
  );
  await db.exec(
    await readFile(
      new URL(
        "../../supabase/migrations/" + emailDomainMigration,
        import.meta.url,
      ),
      "utf8",
    ),
  );
  boundDelivery = true;
  same(
    "migration disables unknown configuration",
    await value("select enabled from taskfold_private.email_intake_config"),
    false,
  );
  same(
    "legacy active and paused addresses are revoked without guessing domain",
    await value(
      "select bool_and(state='revoked' and alias_domain is null) from taskfold_private.email_routes",
    ),
  );
  same(
    "migration handles maximum legacy revision without overflow",
    await value(
      "select revision from taskfold_private.email_routes where id=$1",
      [id(24)],
    ),
    2147483647,
  );
  same(
    "migration preserves every task and delivery receipt",
    await value(
      "select jsonb_build_object('tasks',(select jsonb_agg(to_jsonb(t) order by id) from public.tasks t),'receipts',(select jsonb_agg(to_jsonb(d) order by route_id) from taskfold_private.email_deliveries d))",
    ),
    before,
  );
  same(
    "new RPC declares wire protocol two",
    (await manage("list")).protocol,
    2,
  );
  same(
    "legacy metadata retains unknown revoked domain",
    (await manage("list")).routes.every((r) =>
      r.alias_domain === null && r.state === "revoked"
    ),
  );
  for (
    const [i, domain] of [
      "MAIL.example.invalid",
      "mail..invalid",
      "https://mail.example.invalid",
      "user@mail.example.invalid",
      "localhost",
      "a".repeat(63) + "." + "b".repeat(63) + "." + "c".repeat(62),
    ].entries()
  ) {
    await refuse(
      "invalid domain " + i,
      "22023",
      () => configure("synthetic-adapter", domain),
    );
  }
  await refuse(
    "enabled without domain refused",
    "22023",
    () => configure(null, null, true),
  );
  await refuse(
    "partially configured provider refused",
    "22023",
    () => configure("synthetic-adapter", null, false),
  );
  await refuse(
    "unknown enabled flag refused",
    "22023",
    () => configure("synthetic-adapter", a, null),
  );
  await configure("synthetic-adapter", a, false);
  same("disabled configured domain is not advertised", [
    (await manage("list")).available,
    (await manage("list")).domain,
  ], [false, null]);
  same(
    "configuration helper returns canonical domain",
    (await configure()).domain,
    a,
  );
  same(
    "enabled list advertises the database domain",
    (await manage("list")).domain,
    a,
  );
  await refuse(
    "old body cannot enroll without reviewed domain",
    "22023",
    () => manage("create", setup(31, null)),
  );
  await refuse(
    "stale reviewed domain cannot enroll",
    "PT409",
    () => manage("create", setup(31, b)),
  );
  const created = await manage("create", setup(31));
  same(
    "new receipt binds immutable alias domain",
    created.route.alias_domain,
    a,
  );
  await refuse(
    "legacy unknown domain cannot resume",
    "PT409",
    () => manage("resume", { id: id(21), revision: 2, domain: a }),
  );
  await refuse(
    "legacy setup cannot be silently assigned a domain",
    "PT409",
    () => manage("create", setup(21, a)),
  );
  await refuse(
    "active routes prevent domain replacement",
    "PT409",
    () => configure("synthetic-adapter", b),
  );
  await refuse(
    "active routes prevent provider replacement",
    "PT409",
    () => configure("different-adapter", a),
  );
  await refuse(
    "disabling and changing domain together cannot bypass review",
    "PT409",
    () => configure("synthetic-adapter", b, false),
  );
  await configure("synthetic-adapter", a, false);
  await refuse("disabled capture refuses delivery", "PT503", () => deliver(31));
  const paused = await manage("pause", { id: id(31), revision: 1 });
  same("pause stays available while disabled", paused.route.state, "paused");
  await refuse(
    "paused routes still protect their address domain",
    "PT409",
    () => configure("synthetic-adapter", b, false),
  );
  await refuse(
    "resetting configuration cannot bypass existing address ownership",
    "PT409",
    () => configure(null, null, false),
  );
  await configure();
  await refuse(
    "resume requires explicit reviewed domain",
    "22023",
    () => manage("resume", { id: id(31), revision: 2 }),
  );
  await refuse(
    "resume cannot silently switch an alias domain",
    "PT409",
    () => manage("resume", { id: id(31), revision: 2, domain: b }),
  );
  same(
    "correct reviewed resume remains available",
    (await manage("resume", { id: id(31), revision: 2, domain: a })).route
      .state,
    "active",
  );
  await refuse(
    "extra domain on pause is refused",
    "22023",
    () => manage("pause", { id: id(31), revision: 3, domain: a }),
  );
  await refuse(
    "direct admin update also respects live-address guard",
    "PT409",
    () =>
      db.exec(
        "update taskfold_private.email_intake_config set domain='capture.example.invalid'",
      ),
  );
  await db.exec("begin isolation level repeatable read");
  await refuse(
    "configuration refuses a stale snapshot transaction",
    "25000",
    () => configure(),
  );
  await db.exec("rollback");
  await db.exec("begin isolation level serializable");
  await refuse(
    "serializable configuration also uses explicit supported isolation",
    "25000",
    () => configure(),
  );
  await db.exec("rollback");
  await refuse(
    "active row cannot lose its domain",
    "23514",
    () =>
      q(
        "update taskfold_private.email_routes set alias_domain=null where id=$1",
        [id(31)],
      ),
  );
  await manage("revoke", { id: id(31), revision: 3 });
  same(
    "configuration may change after explicit revocation",
    (await configure("synthetic-adapter", b)).domain,
    b,
  );
  same(
    "revoked old address retains original domain",
    (await manage("list")).routes.find((r) => r.id === id(31)).alias_domain,
    a,
  );
  await refuse(
    "stale worker cannot enroll against changed database domain",
    "PT409",
    () => manage("create", setup(32, a)),
  );
  const next = await manage("create", setup(32, b));
  same("fresh setup uses new reviewed domain", next.route.alias_domain, b);
  await refuse(
    "verified recipient domain cannot disagree with route",
    "PT404",
    () => deliver(32, a),
  );
  await refuse(
    "old delivery helper cannot guess an attested domain",
    "PT428",
    () =>
      value(
        "select public.taskfold_email_deliver($1,'synthetic-adapter','old-wire',now(),'domain-owner@example.invalid',$2::jsonb)",
        [
          setup(32).alias_hash,
          JSON.stringify({
            title: "Old caller",
            description: "",
            attachmentCount: 0,
          }),
        ],
      ),
  );
  same(
    "old delivery endpoint has no service role grant",
    await value(
      "select has_function_privilege('service_role','public.taskfold_email_deliver(text,text,text,timestamptz,text,jsonb)','EXECUTE')",
    ),
    false,
  );
  same(
    "new delivery endpoint is service-only",
    await value(
      "select has_function_privilege('service_role','public.taskfold_email_deliver_v2(text,text,text,text,timestamptz,text,jsonb)','EXECUTE')",
    ),
  );
  same(
    "new domain can capture one task",
    (await deliver(32, b)).accepted,
    true,
  );
  await refuse(
    "known revoked old address cannot capture",
    "PT404",
    () => deliver(31),
  );
  for (const role of ["anon", "authenticated"]) {
    same(
      role + " cannot execute verified-domain delivery",
      await value(
        "select has_function_privilege($1,'public.taskfold_email_deliver_v2(text,text,text,text,timestamptz,text,jsonb)','EXECUTE')",
        [role],
      ),
      false,
    );
    same(
      role + " has no configuration EXECUTE",
      await value(
        "select has_function_privilege($1,'public.taskfold_email_configure(text,text,boolean)','EXECUTE')",
        [role],
      ),
      false,
    );
  }
  same(
    "service role owns configuration capability",
    await value(
      "select has_function_privilege('service_role','public.taskfold_email_configure(text,text,boolean)','EXECUTE')",
    ),
  );
  await db.exec("set role authenticated");
  await refuse(
    "actual native role cannot attest delivery domains",
    "42501",
    () => deliver(32, b),
  );
  await refuse(
    "actual native role cannot configure provider",
    "42501",
    () => configure(),
  );
  await db.exec("reset role");
  same(
    "configuration public wrapper remains invoker",
    await value(
      "select not prosecdef from pg_proc where oid='public.taskfold_email_configure(text,text,boolean)'::regprocedure",
    ),
  );
  same(
    "legacy migration did not erase original task",
    await value(
      "select count(*)::int from public.tasks where title='Synthetic original mail'",
    ),
    2,
  );
  summary.passed = true;
} catch (error) {
  summary.passed = false;
  summary.failure = { message: error.message, code: error.code };
  process.exitCode = 1;
} finally {
  await db.close();
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(summary, null, 2) + "\n");
  }
  console.log(JSON.stringify(summary));
}
