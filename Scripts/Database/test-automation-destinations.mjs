// Owned synthetic schema + actual candidate SQL. No hosted task data or secrets.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
const db = new PGlite({ extensions: { pgcrypto } });
const id = (n) => "f099cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const a = id(1),
  b = id(2),
  key = id(11),
  writeKey = id(12),
  hash = "a".repeat(64);
let checks = 0;
const same = (a, b, message) => {
  assert.deepEqual(a, b, message);
  checks++;
};
const q = async (sql, args = []) => (await db.query(sql, args)).rows;
const v = async (sql, args = []) => Object.values((await q(sql, args))[0])[0];
const load = async (path) =>
  db.exec(await readFile(new URL(path, import.meta.url), "utf8"));
const read = (action, body = {}, k = key, h = hash) =>
  v("select public.taskfold_automation_destinations($1,$2,$3,$4::jsonb)", [
    k,
    h,
    action,
    JSON.stringify(body),
  ]);
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
  await load("./account-removal-bootstrap.sql");
  await load(
    "../../supabase/migrations/20261022193804_account_removal_service.sql",
  );
  await load("./automation-task-bootstrap.sql");
  await db.exec(
    `alter table public.tasks add column task_generation uuid,add column completion_version bigint default 0;
 alter table public.projects add column color text,add column order_index integer,add column parent_id uuid references public.projects(id),add column is_archived boolean default false,add column ancestor_archived boolean default false,add column fixture_private text;
 create table public.sections(id uuid primary key,project_id uuid references public.projects(id) on delete cascade,user_id uuid,name text,order_index integer,created_at timestamptz,fixture_private text);`,
  );
  for (
    const f of [
      "20261022212224_automation_access.sql",
      "20261022220821_automation_task_access.sql",
      "20261023010559_automation_destinations.sql",
    ]
  ) await load("../../supabase/migrations/" + f);
  await q("insert into auth.users(id,email) values($1,$2),($3,$4)", [
    a,
    "dest-a@example.invalid",
    b,
    "dest-b@example.invalid",
  ]);
  for (
    const [k, scopes] of [[key, ["tasks:read"]], [writeKey, ["tasks:create"]]]
  ) {
    await q(
      "insert into taskfold_private.automation_keys(id,user_id,name,token_hash,scopes,ttl_days,expires_at) values($1,$2,'Synthetic tool',$3,$4,30,clock_timestamp()+interval '1 day')",
      [k, a, k === key ? hash : "c".repeat(64), scopes],
    );
  }
  for (
    const [n, owner, name, order, archived, ancestor] of [
      [20, b, "PRIVATE PARENT", 0, false, false],
      [21, a, "Own", 4, false, false],
      [22, b, "Shared child", 1, false, false],
      [23, a, "Archived", 2, true, false],
      [24, a, "Under archive", 3, false, true],
      [25, b, "Pending", 5, false, false],
    ]
  ) {
    await q(
      "insert into public.projects(id,user_id,name,color,order_index,is_archived,ancestor_archived,fixture_private) values($1,$2,$3,'purple',$4,$5,$6,'PRIVATE SETTINGS')",
      [id(n), owner, name, order, archived, ancestor],
    );
  }
  await q("update public.projects set parent_id=$1 where id=$2", [
    id(20),
    id(22),
  ]);
  await q("insert into public.profiles(user_id) values($1),($2)", [a, b]);
  await q("select set_config('request.jwt.claim.sub',$1,false)", [b]);
  await q(
    "insert into public.project_collaborators(id,project_id,invited_email,invited_by) values($1,$2,'dest-a@example.invalid',$3),($4,$5,'dest-a@example.invalid',$3)",
    [id(30), id(22), b, id(31), id(25)],
  );
  await q("select set_config('request.jwt.claim.sub',$1,false)", [a]);
  await q(
    "update public.project_collaborators set status='accepted' where id=$1",
    [id(30)],
  );
  for (
    const [n, p, order] of [[40, 21, 2], [41, 21, 1], [42, 22, 0], [43, 20, 0]]
  ) {
    await q(
      "insert into public.sections(id,project_id,user_id,name,order_index,fixture_private) values($1,$2,$3,$4,$5,'PRIVATE SECTION')",
      [id(n), id(p), b, "Section " + n, order],
    );
  }
  await db.exec("set role service_role");
  const first = await read("projects", { limit: 2 });
  same(
    first.projects.map((p) => p.id),
    [id(21), id(22)],
    "Own and accepted project only",
  );
  same(first.next_cursor, id(22));
  same(first.inbox, { name: "Inbox", project_id: null, section_id: null });
  same(first.projects[1].parent_id, null, "Hidden ancestor identity");
  same(first.projects[1].parent_unavailable, true);
  same(
    first.projects.map((p) => p.order_index),
    [4, 1],
    "Native order retained independently of UUID pagination",
  );
  same(first.projects[0].accepts_tasks, true);
  same(
    Object.keys(first.projects[0]).sort(),
    [
      "accepts_tasks",
      "ancestor_archived",
      "color",
      "id",
      "is_archived",
      "name",
      "order_index",
      "parent_id",
      "parent_unavailable",
    ].sort(),
  );
  const last = await read("projects", { limit: 2, after: first.next_cursor });
  same(last.projects.map((p) => p.id), [id(23), id(24)]);
  same(last.next_cursor, null);
  same(last.projects.map((p) => p.accepts_tasks), [false, false]);
  const sectionPage = await read("sections", { project_id: id(21), limit: 1 });
  same(sectionPage.sections, [{
    id: id(40),
    project_id: id(21),
    name: "Section 40",
    order_index: 2,
  }]);
  same(sectionPage.next_cursor, id(40));
  same(
    (await read("sections", { project_id: id(21), after: id(40), limit: 1 }))
      .sections[0].id,
    id(41),
  );
  same(
    (await read("sections", { project_id: id(23) })).sections,
    [],
    "Archived sections remain readable",
  );
  await refuses("PT404", () => read("sections", { project_id: id(20) }));
  await refuses("PT404", () => read("sections", { project_id: id(25) }));
  await refuses(
    "PT404",
    () => read("sections", { project_id: id(22), after: id(40) }),
  );
  await refuses("PT404", () => read("projects", { after: id(20) }));
  await refuses("PT404", () => read("projects", { after: id(999) }));
  for (
    const [action, body] of [
      ["sections", {}],
      ["sections", { project_id: null }],
      ["projects", { project_id: id(21) }],
      ["projects", { limit: 0 }],
      ["projects", { limit: 51 }],
      ["projects", { limit: 1.5 }],
      ["projects", { limit: "2" }],
      ["projects", { after: null }],
      ["projects", { unknown: true }],
      ["nope", {}],
    ]
  ) await refuses("22023", () => read(action, body));
  await refuses("42501", () => read("projects", {}, writeKey, "c".repeat(64)));
  await refuses("28000", () => read("projects", {}, key, "b".repeat(64)));
  await db.exec("reset role");
  await q(
    "update public.project_collaborators set status='pending' where id=$1",
    [id(30)],
  );
  await refuses("PT404", () => read("projects", { after: id(22) }));
  await refuses("PT404", () => read("sections", { project_id: id(22) }));
  same(
    (await read("projects")).projects.some((p) => p.id === id(22)),
    false,
    "Membership removed between pages",
  );
  await q(
    "update public.project_collaborators set status='accepted' where id=$1",
    [id(30)],
  );
  await q("update public.projects set parent_id=$1 where id=$2", [
    id(21),
    id(22),
  ]);
  const child = (await read("projects")).projects.find((p) => p.id === id(22));
  same(child.parent_id, id(21));
  same(child.parent_unavailable, false);
  await q("update public.projects set name=repeat('x',1048576) where id=$1", [
    id(21),
  ]);
  await refuses("PT413", () => read("projects"));
  await q("update public.projects set name='Own' where id=$1", [id(21)]);
  await q("update public.sections set name=repeat('x',1048576) where id=$1", [
    id(40),
  ]);
  await refuses("PT413", () => read("sections", { project_id: id(21) }));
  await q("update public.sections set name='Section 40' where id=$1", [id(40)]);
  const before = await v(
    "select day_requests from taskfold_private.automation_keys where id=$1",
    [key],
  );
  await refuses("22023", () => read("projects", { limit: 0 }));
  same(
    await v(
      "select day_requests from taskfold_private.automation_keys where id=$1",
      [key],
    ),
    before,
    "Failed read rolls back quota",
  );
  await read("projects");
  same(
    await v(
      "select day_requests from taskfold_private.automation_keys where id=$1",
      [key],
    ),
    before + 1,
    "One quota charge",
  );
  await q(
    "update taskfold_private.automation_keys set window_requests=60 where id=$1",
    [key],
  );
  await refuses("PT429", () => read("projects"));
  await q(
    "update taskfold_private.automation_keys set window_requests=0,revoked_at=clock_timestamp() where id=$1",
    [key],
  );
  await refuses("28000", () => read("projects"));
  for (const role of ["anon", "authenticated"]) {
    same(
      await v(
        "select has_function_privilege($1,'public.taskfold_automation_destinations(uuid,text,text,jsonb)','EXECUTE')",
        [role],
      ),
      false,
      "No client RPC access",
    );
  }
  same(
    await v(
      "select has_function_privilege('service_role','public.taskfold_automation_destinations(uuid,text,text,jsonb)','EXECUTE')",
    ),
    true,
  );
  // Break self-reference for fixture cleanup only; no production data is involved.
  await q("update public.projects set parent_id=null");
  await q("delete from auth.users where id in($1,$2)", [a, b]);
  same(await v("select count(*)::int from auth.users"), 0);
  console.log(
    `PASS ${checks} actual local destination SQL assertions; no hosted/race acceptance.`,
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
