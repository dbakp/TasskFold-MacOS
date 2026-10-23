import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
const db = new PGlite({ extensions: { pgcrypto } });
const id = (n) => "f098cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const a = id(1), b = id(2), c = id(3), sa = id(11), sb = id(12), sc = id(13);
let checks = 0;
const same = (actual, expected, message) => {
  assert.deepEqual(actual, expected, message);
  checks++;
};
const query = async (sql, args = []) => (await db.query(sql, args)).rows;
const value = async (sql, args = []) =>
  Object.values((await query(sql, args))[0])[0];
const hash = (key) => createHash("sha256").update(key).digest("hex");
const create = (account, session, key) =>
  value("select public.taskfold_automation_keys($1,$2,'create',$3::jsonb)", [
    account,
    session,
    JSON.stringify({
      id: key,
      name: "Synthetic tool",
      token_hash: hash(key),
      scopes: ["tasks:read"],
      ttl_days: 30,
    }),
  ]);
const cancel = (account, session, key) =>
  value("select public.taskfold_automation_cancel_key($1,$2,$3)", [
    account,
    session,
    key,
  ]);
const receipt = (account, key) => ({ account, id: key, cancelled: true });
async function refuses(code, work) {
  let failed = false;
  try {
    await work();
  } catch (e) {
    same(e.code, code, e.message);
    failed = true;
  }
  same(failed, true, "Expected refusal");
}
try {
  await db.exec(
    "create schema extensions;create extension pgcrypto with schema extensions",
  );
  for (
    const path of [
      "./account-removal-bootstrap.sql",
      "../../supabase/migrations/20261022193804_account_removal_service.sql",
      "../../supabase/migrations/20261022212224_automation_access.sql",
      "../../supabase/migrations/20261023002825_automation_enrollment_cancellation.sql",
    ]
  ) {
    await db.exec(await readFile(new URL(path, import.meta.url), "utf8"));
  }
  for (const [owner, session] of [[a, sa], [b, sb], [c, sc]]) {
    await query("insert into auth.users(id,email) values($1,$2)", [
      owner,
      "cancellation-" + owner + "@example.invalid",
    ]);
    await query(
      "insert into auth.sessions(id,user_id,not_after) values($1,$2,clock_timestamp()+interval '1 day')",
      [session, owner],
    );
  }
  await db.exec("set role service_role");
  same(
    await cancel(a, sa, id(100)),
    receipt(a, id(100)),
    "Real service role can cancel unknown enrollment",
  );
  await db.exec("reset role");
  same(
    await value("select count(*)::int from taskfold_private.automation_keys"),
    0,
    "Cancellation never issues a key",
  );
  same(
    await cancel(a, sa, id(100)),
    receipt(a, id(100)),
    "Exact cancellation retries succeed",
  );
  same(
    await value(
      "select count(*)::int from taskfold_private.automation_key_cancellations",
    ),
    1,
    "No duplicate history",
  );
  await refuses("PT409", () => create(a, sa, id(100)));
  same(
    await value("select count(*)::int from taskfold_private.automation_keys"),
    0,
    "Late creation has no effect",
  );
  await create(b, sb, id(100));
  same(
    await cancel(a, sa, id(100)),
    receipt(a, id(100)),
    "Foreign key has generic cancellation receipt",
  );
  same(
    await value(
      "select revoked_at is null from taskfold_private.automation_keys where id=$1",
      [id(100)],
    ),
    true,
    "Foreign account key untouched",
  );
  same(
    await value(
      "select taskfold_private.automation_authorize($1,$2,'tasks:read')",
      [id(100), hash(id(100))],
    ),
    b,
    "Foreign tool remains authorized",
  );
  same(
    await cancel(a, sa, id(101)),
    receipt(a, id(101)),
    "Unknown key response has the same shape",
  );
  const issued = await create(c, sc, id(200));
  same(issued.key.revoked_at, null);
  same(
    await cancel(c, sc, id(200)),
    receipt(c, id(200)),
    "Create-before-cancel revokes owned key",
  );
  const revoked = await value(
    "select revoked_at::text from taskfold_private.automation_keys where id=$1",
    [id(200)],
  );
  same(typeof revoked, "string");
  same(await cancel(c, sc, id(200)), receipt(c, id(200)));
  same(
    await value(
      "select revoked_at::text from taskfold_private.automation_keys where id=$1",
      [id(200)],
    ),
    revoked,
    "Retry preserves revocation time",
  );
  same(
    typeof (await create(c, sc, id(200))).key.revoked_at,
    "string",
    "Old create replay cannot revive the key",
  );
  await refuses(
    "28000",
    () =>
      value(
        "select taskfold_private.automation_authorize($1,$2,'tasks:read')",
        [id(200), hash(id(200))],
      ),
  );
  for (let n = 201; n <= 210; n++) await create(a, sa, id(n));
  await refuses("PT429", () => create(a, sa, id(211)));
  same(
    await cancel(a, sa, id(400)),
    receipt(a, id(400)),
    "Discard works at issuance cap without creating a key",
  );
  same(
    await value(
      "select count(*)::int from taskfold_private.automation_keys where user_id=$1",
      [a],
    ),
    10,
    "No issuance consumed by discard",
  );
  await query(
    "update taskfold_private.automation_keys set created_at=created_at-interval '2 days' where user_id=$1",
    [a],
  );
  await refuses("PT409", () => create(a, sa, id(400)));
  const used = await value(
    "select count(*)::int from taskfold_private.automation_key_cancellations where user_id=$1",
    [a],
  );
  for (let n = 0; n < 100 - used; n++) await cancel(a, sa, id(500 + n));
  same(
    await value(
      "select count(*)::int from taskfold_private.automation_key_cancellations where user_id=$1",
      [a],
    ),
    100,
    "Separate permanent-history bound",
  );
  await refuses("PT429", () => cancel(a, sa, id(900)));
  same(
    await cancel(a, sa, id(400)),
    receipt(a, id(400)),
    "Existing tombstone retry bypasses new-row cap",
  );
  same(
    await cancel(a, sa, id(201)),
    receipt(a, id(201)),
    "Existing-key revocation bypasses tombstone cap",
  );
  same(
    await value(
      "select revoked_at is not null from taskfold_private.automation_keys where id=$1",
      [id(201)],
    ),
    true,
  );
  await refuses("28000", () => cancel(a, sb, id(901)));
  await query(
    "update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id=$1",
    [sc],
  );
  await refuses("28000", () => cancel(c, sc, id(901)));
  await query(
    "update auth.users set banned_until=clock_timestamp()+interval '1 day' where id=$1",
    [b],
  );
  await refuses("28000", () => cancel(b, sb, id(901)));
  await refuses("22023", () => cancel(a, sa, null));
  await refuses(
    "22023",
    () => cancel(a, sa, "00000000-0000-0000-0000-000000000000"),
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    same(
      await value(
        "select has_table_privilege($1,'taskfold_private.automation_key_cancellations','SELECT')",
        [role],
      ),
      false,
      "Private cancellation table",
    );
    same(
      await value(
        "select has_function_privilege($1,'taskfold_private.automation_refuse_cancelled_key()','EXECUTE')",
        [role],
      ),
      false,
      "Private trigger function",
    );
  }
  for (const role of ["anon", "authenticated"]) {
    same(
      await value(
        "select has_function_privilege($1,'public.taskfold_automation_cancel_key(uuid,uuid,uuid)','EXECUTE')",
        [role],
      ),
      false,
      "No direct client RPC",
    );
  }
  same(
    await value(
      "select relrowsecurity from pg_class where oid='taskfold_private.automation_key_cancellations'::regclass",
    ),
    true,
  );
  same(
    await value(
      "select count(*)::int from pg_indexes where schemaname='taskfold_private' and indexname='automation_key_cancellations_owner_date'",
    ),
    1,
  );
  await query("delete from auth.users where id in($1,$2,$3)", [a, b, c]);
  for (
    const table of [
      "auth.users",
      "auth.sessions",
      "taskfold_private.automation_keys",
      "taskfold_private.automation_key_cancellations",
    ]
  ) {
    same(
      await value("select count(*)::int from " + table),
      0,
      "Auth cleanup: " + table,
    );
  }
  console.log(
    `PASS ${checks} actual local cancellation assertions; no hosted Auth/TLS or cross-connection race acceptance.`,
  );
} catch (e) {
  console.error(e.message);
  if (e.where) console.error(e.where);
  process.exitCode = 1;
} finally {
  await db.close();
}
