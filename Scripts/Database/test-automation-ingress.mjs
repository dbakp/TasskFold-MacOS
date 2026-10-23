import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
const db = new PGlite();
let checks = 0;
const same = (a, b, label) => {
  assert.deepEqual(a, b, label);
  checks++;
};
const h = (n) => n.toString(16).padStart(64, "0");
const v = async (sql, args = []) =>
  Object.values((await db.query(sql, args)).rows[0])[0];
const admit = (route = "tasks", ip = h(1), credential = h(2)) =>
  v(
    "select taskfold_private.automation_admit_at($1,$2,$3,'2040-01-01T12:00:10Z'::timestamptz)",
    [
      route,
      ip,
      credential,
    ],
  );
async function refuses(code, work) {
  let failed = false;
  try {
    await work();
  } catch (e) {
    same(e.code, code, e.message);
    failed = true;
  }
  same(failed, true);
}
try {
  await db.exec(
    "create role anon;create role authenticated;create role service_role;create schema taskfold_private;grant usage on schema taskfold_private to service_role",
  );
  await db.exec(
    await readFile(
      new URL(
        "../../supabase/migrations/20261023012417_automation_ingress_limits.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  await db.exec("set role service_role");
  same(
    await v("select public.taskfold_automation_admit($1,$2,$3)", [
      "tasks",
      h(1),
      h(2),
    ]),
    { allowed: true, retry_after: 0, limited_by: null },
  );
  await db.exec("reset role");
  // Keep tests in one synthetic minute without depending on real wall-clock timing.
  const reset = () => db.exec("truncate taskfold_private.automation_ingress");
  await reset();
  for (let n = 0; n < 120; n++) {
    same((await admit("tasks", h(1), h(n + 100))).allowed, true);
  }
  let result = await admit("tasks", h(1), h(999));
  same(result.allowed, false);
  same(result.limited_by, "ip");
  same(result.retry_after >= 1 && result.retry_after <= 60, true);
  same(
    await v(
      "select hits from taskfold_private.automation_ingress where route='tasks' and dimension='global'",
    ),
    121,
    "Rejected admission remains charged globally",
  );
  same(
    await v(
      "select count(*)::int from taskfold_private.automation_ingress where dimension='credential' and fingerprint=$1",
      [h(999)],
    ),
    0,
    "No new credential after IP denial",
  );
  await reset();
  for (let n = 0; n < 120; n++) await admit("tasks", h(n + 100), h(2));
  same((await admit("tasks", h(999), h(2))).limited_by, "credential");
  // Saturate the global route budget through independent IP/credential pairs.
  await reset();
  for (let n = 0; n < 1200; n++) await admit("tasks", h(n + 100), h(n + 2000));
  result = await admit("tasks", h(9000), h(9001));
  same(result.limited_by, "global");
  same(result.allowed, false);
  same(
    await v("select count(*)::int from taskfold_private.automation_ingress"),
    2401,
    "Global cap bounds distinct per-window rows",
  );
  for (let n = 0; n < 5; n++) await admit("tasks", h(10000 + n), h(11000 + n));
  same(
    await v("select count(*)::int from taskfold_private.automation_ingress"),
    2401,
    "Rotated denied identities allocate no rows",
  );
  same(
    (await admit("keys", h(1), h(2))).allowed,
    true,
    "Task exhaustion cannot consume management/revocation route",
  );
  await reset();
  for (let n = 0; n < 60; n++) await admit("keys", h(1), h(n + 100));
  same((await admit("keys", h(1), h(999))).limited_by, "ip");
  await reset();
  for (let n = 0; n < 60; n++) await admit("keys", h(n + 100), h(2));
  same((await admit("keys", h(999), h(2))).limited_by, "credential");
  await reset();
  for (let n = 0; n < 600; n++) await admit("keys", h(n + 100), h(n + 2000));
  same((await admit("keys", h(9000), h(9001))).limited_by, "global");
  // Expired windows reset; TTL cleanup touches at most 128 transient rows/call.
  await db.exec(
    "update taskfold_private.automation_ingress set window_start='2040-01-01T11:50:00Z'::timestamptz,expires_at='2040-01-01T11:55:00Z'::timestamptz",
  );
  same(
    (await admit("keys", h(1), h(2))).allowed,
    true,
    "Minute rollover recovers without clearing durable credentials",
  );
  same(
    await v(
      "select count(*)::int from taskfold_private.automation_ingress where dimension<>'global' and expires_at<='2040-01-01T12:00:10Z'::timestamptz",
    ),
    1072,
    "Bounded indexed expiry sweep",
  );
  // A later independent operation failing cannot roll back an already committed gate.
  const hits = await v(
    "select hits from taskfold_private.automation_ingress where route='keys' and dimension='global'",
  );
  await refuses("22012", () => v("select 1/0"));
  same(
    await v(
      "select hits from taskfold_private.automation_ingress where route='keys' and dimension='global'",
    ),
    hits,
  );
  for (
    const [route, ip, credential] of [
      ["bad", h(1), h(2)],
      ["tasks", "raw IP", h(2)],
      ["tasks", h(1), "raw token"],
      [null, h(1), h(2)],
    ]
  ) await refuses("22023", () => admit(route, ip, credential));
  for (const role of ["anon", "authenticated"]) {
    same(
      await v(
        "select has_function_privilege($1,'public.taskfold_automation_admit(text,text,text)','EXECUTE')",
        [role],
      ),
      false,
    );
  }
  for (const role of ["anon", "authenticated", "service_role"]) {
    same(
      await v(
        "select has_table_privilege($1,'taskfold_private.automation_ingress','SELECT')",
        [role],
      ),
      false,
    );
  }
  same(
    await v(
      "select has_function_privilege('service_role','taskfold_private.automation_admit_at(text,text,text,timestamptz)','EXECUTE')",
    ),
    false,
    "Service cannot provide its own clock",
  );
  same(
    await v(
      "select relrowsecurity from pg_class where oid='taskfold_private.automation_ingress'::regclass",
    ),
    true,
  );
  same(
    await v(
      "select count(*)::int from information_schema.columns where table_schema='taskfold_private' and table_name='automation_ingress' and column_name in('ip','token','account','user_id','body')",
    ),
    0,
    "No raw identifiers or payload columns",
  );
  await reset();
  same(
    await v("select count(*)::int from taskfold_private.automation_ingress"),
    0,
  );
  console.log(
    `PASS ${checks} actual local admission SQL assertions. Sequential fixed-window/TTL/ACL/privacy proof, not hosted proxy or cross-connection acceptance.`,
  );
} catch (e) {
  console.error(e.message, e.where ?? "");
  if (e.actual !== undefined) {
    console.error({ actual: e.actual, expected: e.expected });
  }
  process.exitCode = 1;
} finally {
  await db.close();
}
