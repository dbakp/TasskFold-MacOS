// No network/config/credentials. Each repo owns the complete local test inputs.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
const db = new PGlite({ extensions: { pgcrypto } });
let checks = 0;
const same = (a, b, message) => {
  assert.deepEqual(a, b, message);
  checks++;
};
async function sql(query, args = []) {
  return (await db.query(query, args)).rows;
}
const value = async (query, args = []) =>
  Object.values((await sql(query, args))[0])[0];
const uuid = (n) =>
  "f093cafe-0000-4000-8000-" + n.toString(16).padStart(12, "0");
const a = uuid(1),
  b = uuid(2),
  c = uuid(3),
  session = uuid(11),
  key = uuid(21),
  readKey = uuid(22),
  bKey = uuid(23),
  project = uuid(31),
  otherProject = uuid(32);
const task = uuid(41),
  inbox = uuid(42),
  outside = uuid(43),
  pending = uuid(44),
  hiddenOwned = uuid(45),
  pendingProject = uuid(33),
  foreignProject = uuid(34);
const hash = "1".repeat(64), readHash = "2".repeat(64), bHash = "3".repeat(64);
const body = { changes: { title: "Changed by automation" } };
async function refuses(code, query, args = []) {
  let caught = false;
  try {
    await db.query(query, args);
  } catch (error) {
    caught = true;
    assert.equal(error.code, code, error.message);
  }
  assert(caught, "Expected refusal " + code);
  checks++;
}
async function tx(work) {
  await db.exec("begin");
  try {
    const result = await work();
    await db.exec("commit");
    return result;
  } catch (e) {
    await db.exec("rollback");
    throw e;
  }
}
async function load(name) {
  await db.exec(await readFile(new URL(name, import.meta.url), "utf8"));
}
const read = (action, body = {}, id = key, tokenHash = hash) =>
  value("select public.taskfold_automation_read($1,$2,$3,$4::jsonb)", [
    id,
    tokenHash,
    action,
    JSON.stringify(body),
  ]);
const begin = async (
  request,
  operation = "update",
  target = task,
  generation = null,
  payload = body,
  id = key,
  tokenHash = hash,
  createProject = null,
) =>
  value(
    "select taskfold_private.automation_request_begin($1,$2,$3,$4,$5,$6,$7::jsonb,$8)",
    [
      id,
      tokenHash,
      request,
      operation,
      target,
      generation,
      JSON.stringify(payload),
      createProject,
    ],
  );
const finish = (
  request,
  generation,
  revision,
  successor = null,
  successorGeneration = null,
) =>
  value(
    "select taskfold_private.automation_request_finish($1,$2,$3,$4,$5,$6)",
    [a, request, generation, revision, successor, successorGeneration],
  );
const current = (id = task) =>
  value("select to_jsonb(t) from public.tasks t where id=$1", [id]);
async function patch(baseline, changes) {
  return value(
    "select to_jsonb(public.taskfold_patch_task($1,$2::jsonb,$3::jsonb))",
    [baseline.id, JSON.stringify({ ...baseline }), JSON.stringify(changes)],
  );
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
  // Extract the actual generation table/guard/record routines, excluding unrelated
  // reminder-device schema dependencies. Fail if the known boundary disappears.
  const generation = await readFile(
    new URL(
      "../../supabase/migrations/20261006124947_task_generations_and_reminder_eligibility.sql",
      import.meta.url,
    ),
    "utf8",
  );
  const boundary = generation.indexOf(
    "-- The read-only remote activation epoch",
  );
  assert(boundary > 0);
  await db.exec(generation.slice(0, boundary));
  await load(
    "../../supabase/migrations/20261006031648_completion_revision.sql",
  );
  await load(
    "../../supabase/migrations/20261020194217_subtask_structure_review.sql",
  );
  await db.exec(
    "create trigger taskfold_timestamp before update on public.tasks for each row execute function public.update_completed_at()",
  );
  await load("../../supabase/migrations/20261022212224_automation_access.sql");
  await load(
    "../../supabase/migrations/20261022215836_automation_recurrence_plan.sql",
  );
  await load(
    "../../supabase/migrations/20261022220821_automation_task_access.sql",
  );
  await sql("insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6)", [
    a,
    "automation-a@example.invalid",
    b,
    "automation-b@example.invalid",
    c,
    "automation-c@example.invalid",
  ]);
  await sql("insert into public.profiles(user_id) values($1),($2),($3)", [
    a,
    b,
    c,
  ]);
  await sql("insert into auth.sessions(id,user_id) values($1,$2)", [
    session,
    a,
  ]);
  await sql(
    "insert into public.projects(id,user_id,name) values($1,$2,$3),($4,$5,$6),($7,$8,$9),($10,$11,$12)",
    [
      project,
      b,
      "Accepted project",
      otherProject,
      b,
      "Private project",
      pendingProject,
      b,
      "Pending project",
      foreignProject,
      c,
      "Lost-access owned task",
    ],
  );
  // Follow owner invite -> member accept with the actual invitation normalizer.
  await sql("select set_config('request.jwt.claim.sub',$1,false)", [b]);
  for (const [id, p] of [[uuid(51), project], [uuid(52), pendingProject]]) {
    await sql(
      "insert into public.project_collaborators(id,project_id,invited_email,invited_by) values($1,$2,$3,$4)",
      [id, p, "automation-a@example.invalid", b],
    );
  }
  await sql("select set_config('request.jwt.claim.sub',$1,false)", [a]);
  await sql(
    "update public.project_collaborators set status='accepted' where id=$1",
    [uuid(51)],
  );
  for (
    const [id, owner, p, title] of [
      [task, b, project, "Accepted shared task"],
      [inbox, a, null, "Own inbox"],
      [outside, b, otherProject, "OUTSIDER PRIVATE TITLE"],
      [pending, b, pendingProject, "PENDING PRIVATE TITLE"],
      [hiddenOwned, a, foreignProject, "LOST ACCESS PRIVATE TITLE"],
    ]
  ) {
    await sql(
      "insert into public.tasks(id,user_id,project_id,title) values($1,$2,$3,$4)",
      [id, owner, p, title],
    );
  }
  const register = (id, owner, h, scopes) =>
    sql(
      "insert into taskfold_private.automation_keys(id,user_id,name,token_hash,scopes,ttl_days,expires_at) values($1,$2,'Local fixture',$3,$4,30,clock_timestamp()+interval '30 days')",
      [id, owner, h, scopes],
    );
  await register(key, a, hash, [
    "tasks:read",
    "tasks:create",
    "tasks:update",
    "tasks:complete",
    "tasks:delete",
  ]);
  await register(readKey, a, readHash, ["tasks:read"]);
  await register(bKey, b, bHash, ["tasks:read", "tasks:update"]);

  // Exercise actual ACL/RLS roles, beyond catalog-only assertions.
  await db.exec("set role authenticated");
  same(
    (await sql("select id from public.tasks order by id")).map((x) => x.id),
    [task, inbox],
    "Native RLS access matches explicit read boundary",
  );
  await refuses(
    "42501",
    "select public.taskfold_automation_read($1,$2,$3,$4::jsonb)",
    [key, hash, "list", "{}"],
  );
  await db.exec("reset role;set role service_role");
  same(
    (await read("get", { id: task })).task.id,
    task,
    "Service wrapper executes private same-transaction authorization",
  );
  await refuses("42501", "select * from taskfold_private.automation_requests");
  await refuses(
    "42501",
    "select taskfold_private.automation_request_begin($1,$2,$3,$4,$5,null,$6::jsonb,null)",
    [key, hash, uuid(500), "update", task, "{}"],
  );
  await db.exec("reset role");
  const g = (await current()).task_generation;
  same(
    (await read("get", { id: task })).task.title,
    "Accepted shared task",
    "Accepted collaborator reads another owner task",
  );
  same(
    (await read("list", {})).tasks.map((x) => x.id),
    [task, inbox],
    "Only accessible project and inbox records",
  );
  same((await read("list", { project_id: null })).tasks.map((x) => x.id), [
    inbox,
  ], "Explicit inbox filter");
  const page = await read("list", { limit: 1 });
  same(page.tasks.map((x) => x.id), [task]);
  same(page.next_cursor, task);
  const last = await read("list", { limit: 1, after: page.next_cursor });
  same(last.tasks.map((x) => x.id), [inbox]);
  same(last.next_cursor, null);
  for (const id of [outside, pending, hiddenOwned, uuid(999)]) {
    await refuses(
      "PT404",
      "select public.taskfold_automation_read($1,$2,$3,$4::jsonb)",
      [key, hash, "get", JSON.stringify({ id })],
    );
  }
  for (
    const input of [
      { limit: 0 },
      { limit: 51 },
      { limit: 1.2 },
      { limit: "1" },
      { completed: null },
      { project_id: "no" },
      { after: null },
      { future: true },
    ]
  ) {
    await refuses(
      "22023",
      "select public.taskfold_automation_read($1,$2,$3,$4::jsonb)",
      [key, hash, "list", JSON.stringify(input)],
    );
  }
  await refuses(
    "PT404",
    "select public.taskfold_automation_read($1,$2,$3,$4::jsonb)",
    [key, hash, "list", JSON.stringify({ after: outside })],
  );
  await refuses(
    "PT404",
    "select public.taskfold_automation_read($1,$2,$3,$4::jsonb)",
    [key, hash, "list", JSON.stringify({ project_id: otherProject })],
  );
  await db.exec(
    "alter table public.tasks add column future_private_column text default 'FUTURE PRIVATE VALUE'",
  );
  same(
    JSON.stringify(await read("get", { id: task })).includes("FUTURE PRIVATE"),
    false,
    "Explicit fields exclude future columns",
  );
  await db.exec("alter table public.tasks drop column future_private_column");
  await sql(
    "update public.tasks set description=repeat('x',260000) where id=$1",
    [inbox],
  );
  await refuses(
    "PT413",
    "select public.taskfold_automation_read($1,$2,$3,$4::jsonb)",
    [key, hash, "get", JSON.stringify({ id: inbox })],
  );
  await sql("update public.tasks set description=null where id=$1", [inbox]);
  // Actual native guarded patch inside the same journal transaction.
  const request = uuid(61);
  let receipt;
  await tx(async () => {
    same((await begin(request, "update", task, g)).replayed, false);
    const result = await patch(await current(), body.changes);
    same(result.title, body.changes.title);
    receipt = await finish(request, g, result.completion_version);
    same(receipt.task_id, task);
  });
  await sql("update public.tasks set title=$1 where id=$2", [
    "Newer device title",
    task,
  ]);
  const replay = await begin(request, "update", task, g);
  same(replay.replayed, true);
  same(replay.receipt, receipt);
  same(
    (await current()).title,
    "Newer device title",
    "Replay never reapplies old edit",
  );
  await refuses(
    "PT409",
    "select taskfold_private.automation_request_begin($1,$2,$3,$4,$5,$6,$7::jsonb,null)",
    [
      key,
      hash,
      request,
      "update",
      task,
      g,
      JSON.stringify({ changes: { title: "Different" } }),
    ],
  );
  // Failed native merge rolls back both claim and effect; same nonce may then retry.
  const conflict = uuid(62);
  const stale = await current();
  await sql("update public.tasks set title=$1 where id=$2", [
    "Concurrent title",
    task,
  ]);
  let failed = false;
  try {
    await tx(async () => {
      await begin(conflict, "update", task, g);
      await patch(stale, body.changes);
      await finish(conflict, g, 0);
    });
  } catch (e) {
    assert(e.message.includes("TASKFOLD_CONFLICT"));
    failed = true;
  }
  same(failed, true);
  same(
    await value(
      "select count(*)::int from taskfold_private.automation_requests where request_id=$1",
      [conflict],
    ),
    0,
    "Failed effect leaves no request claim",
  );
  await tx(async () => {
    await begin(conflict, "update", task, g);
    const r = await patch(await current(), body.changes);
    await finish(conflict, g, r.completion_version);
  });
  // A pending claim cannot commit, even if a future caller forgets finish.
  let unfinished = false;
  try {
    await tx(async () => {
      await begin(uuid(63), "update", task, g);
      await patch(await current(), { description: "MUST ROLL BACK" });
    });
  } catch (e) {
    same(e.code, "PT409");
    unfinished = true;
  }
  same(unfinished, true);
  same((await current()).description, null);

  // A completion receipt cannot confirm a still-open task or an invented revision.
  let unconfirmed = false;
  try {
    await tx(async () => {
      await begin(uuid(69), "complete", task, g, {});
      await finish(uuid(69), g, (await current()).completion_version);
    });
  } catch (e) {
    same(e.code, "PT409");
    unconfirmed = true;
  }
  same(unconfirmed, true);
  let wrongRevision = false;
  try {
    await tx(async () => {
      await begin(uuid(70), "update", task, g, {});
      await finish(uuid(70), g, (await current()).completion_version + 1);
    });
  } catch (e) {
    same(e.code, "PT409");
    wrongRevision = true;
  }
  same(wrongRevision, true);
  // Full native completion -> reopen -> same old request: no later cycle repeats.
  const completeRequest = uuid(64);
  let completeReceipt;
  await tx(async () => {
    await begin(completeRequest, "complete", task, g, { completed: true });
    const r = await patch(await current(), {
      completed: true,
      completed_at: "2026-10-23T12:00:00Z",
    });
    completeReceipt = await finish(completeRequest, g, r.completion_version);
  });
  await patch(await current(), { completed: false, completed_at: null });
  const beforeCycle = await current();
  same(
    (await begin(completeRequest, "complete", task, g, { completed: true }))
      .receipt,
    completeReceipt,
  );
  same(
    await current(),
    beforeCycle,
    "Old completion nonce cannot repeat after reopen",
  );

  // Only the test harness owns this privileged pipeline. It demonstrates the
  // future wrapper's transaction/actor pattern without exposing a production
  // mutation RPC. COMMIT runs as service_role after this definer returns.
  await db.exec(
    `create function taskfold_private.fixture_atomic_title(k uuid,h text,rid uuid,tid uuid,g uuid,title text,finish_it boolean) returns void
 language plpgsql security definer set search_path='' as $$
 declare start jsonb; t public.tasks; prior text:=current_setting('request.jwt.claim.sub',true);
 begin
  start:=taskfold_private.automation_request_begin(k,h,rid,'update',tid,g,jsonb_build_object('title',title));
  if (start->>'replayed')::boolean then return;end if;
  perform set_config('request.jwt.claim.sub',start->>'account',true);
  select * into t from public.tasks where id=tid;
  t:=public.taskfold_patch_task(tid,to_jsonb(t),jsonb_build_object('title',title));
  if finish_it then perform taskfold_private.automation_request_finish((start->>'account')::uuid,rid,t.task_generation,t.completion_version);end if;
  perform set_config('request.jwt.claim.sub',coalesce(prior,''),true);
 end $$;
 revoke all on function taskfold_private.fixture_atomic_title(uuid,text,uuid,uuid,uuid,text,boolean) from public,anon,authenticated;
 grant execute on function taskfold_private.fixture_atomic_title(uuid,text,uuid,uuid,uuid,text,boolean) to service_role;`,
  );
  const nativeActor = await value(
    "select current_setting('request.jwt.claim.sub',true)",
  );
  await db.exec("set role service_role");
  await sql(
    "select taskfold_private.fixture_atomic_title($1,$2,$3,$4,$5,$6,true)",
    [key, hash, uuid(67), task, g, "Role-based atomic effect"],
  );
  await refuses(
    "PT409",
    "select taskfold_private.fixture_atomic_title($1,$2,$3,$4,$5,$6,false)",
    [key, hash, uuid(68), task, g, "MUST NEVER COMMIT"],
  );
  await db.exec("reset role");
  same(
    (await current()).title,
    "Role-based atomic effect",
    "Deferred pending-claim rejection rolls back the actual native effect",
  );
  same(
    await value("select current_setting('request.jwt.claim.sub',true)"),
    nativeActor,
    "Scoped actor context restored",
  );
  // Revocation/scope/access are checked before returning even minimal replay receipts.
  await refuses(
    "42501",
    "select taskfold_private.automation_request_begin($1,$2,$3,$4,$5,$6,$7::jsonb,null)",
    [readKey, readHash, request, "update", task, g, JSON.stringify(body)],
  );
  await sql(
    "update public.project_collaborators set status='pending' where id=$1",
    [uuid(51)],
  );
  await refuses(
    "PT404",
    "select taskfold_private.automation_request_begin($1,$2,$3,$4,$5,$6,$7::jsonb,null)",
    [key, hash, request, "update", task, g, JSON.stringify(body)],
  );
  await refuses(
    "PT404",
    "select taskfold_private.automation_request_begin($1,$2,$3,$4,$5,$6,$7::jsonb,null)",
    [
      key,
      hash,
      request,
      "update",
      inbox,
      g,
      JSON.stringify({ changes: { title: "Changed probe" } }),
    ],
  );
  await sql(
    "update public.project_collaborators set status='accepted' where id=$1",
    [uuid(51)],
  );
  await sql(
    "update taskfold_private.automation_keys set revoked_at=clock_timestamp() where id=$1",
    [key],
  );
  await refuses(
    "28000",
    "select taskfold_private.automation_request_begin($1,$2,$3,$4,$5,$6,$7::jsonb,null)",
    [key, hash, request, "update", task, g, JSON.stringify(body)],
  );
  await sql(
    "update taskfold_private.automation_keys set revoked_at=null where id=$1",
    [key],
  );
  // This local restoration is an explicit fixture reset; public management never unrevokes.
  // Delete without recurrence children, using the actual full-row native baseline.
  const deletion = uuid(65);
  await tx(async () => {
    await begin(deletion, "delete", task, g, {});
    same(
      await value("select public.taskfold_delete_task($1,$2::jsonb)", [
        task,
        JSON.stringify(await current()),
      ]),
      true,
    );
    same((await finish(deletion, null, null)).deleted, true);
  });
  same((await begin(deletion, "delete", task, g, {})).replayed, true);
  same(
    (await begin(request, "update", task, g)).receipt,
    receipt,
    "Deleted tasks do not erase old claims",
  );
  await sql(
    "insert into public.tasks(id,user_id,project_id,title) values($1,$2,$3,$4)",
    [task, b, project, "New incarnation"],
  );
  await refuses(
    "PT409",
    "select taskfold_private.automation_request_begin($1,$2,$3,$4,$5,$6,$7::jsonb,null)",
    [key, hash, request, "update", task, g, JSON.stringify(body)],
  );
  same((await current()).title, "New incarnation");
  // Exact create claim lives beyond deletion and prevents creating the same request twice.
  const created = uuid(46), cg = uuid(91), createRequest = uuid(66);
  await tx(async () => {
    await begin(createRequest, "create", created, cg, {}, key, hash);
    await sql(
      "insert into public.tasks(id,user_id,title,task_generation) values($1,$2,$3,$4)",
      [created, a, "Created once", cg],
    );
    await finish(createRequest, cg, 0);
  });
  await sql("delete from public.tasks where id=$1", [created]);
  same((await begin(createRequest, "create", created, cg, {})).replayed, true);
  same(
    await value("select count(*)::int from public.tasks where id=$1", [
      created,
    ]),
    0,
    "Create retry never resurrects a deleted generation",
  );

  let wrongOwner = false;
  try {
    await tx(async () => {
      await begin(
        uuid(71),
        "create",
        uuid(47),
        uuid(92),
        {},
        key,
        hash,
        project,
      );
      await sql(
        "insert into public.tasks(id,user_id,project_id,title,task_generation) values($1,$2,$3,$4,$5)",
        [uuid(47), b, project, "Wrong owner must roll back", uuid(92)],
      );
      await finish(uuid(71), uuid(92), 0);
    });
  } catch (e) {
    same(e.code, "PT409");
    wrongOwner = true;
  }
  same(wrongOwner, true);
  same(
    await value("select count(*)::int from public.tasks where id=$1", [
      uuid(47),
    ]),
    0,
  );
  // Journal rows have no stored request text or prior task response to leak.
  const journal = await value(
    "select jsonb_agg(to_jsonb(r)) from taskfold_private.automation_requests r",
  );
  for (
    const text of [
      "Changed by automation",
      "Newer device title",
      "Created once",
      hash,
    ]
  ) {
    same(
      JSON.stringify(journal).includes(text),
      false,
      "Journal excludes task content and key hash",
    );
  }
  await refuses(
    "PT409",
    "delete from taskfold_private.automation_requests where request_id=$1",
    [request],
  );
  await refuses(
    "PT409",
    "update taskfold_private.automation_requests set result_completion_version=999 where request_id=$1",
    [request],
  );
  await refuses(
    "PT409",
    "update taskfold_private.automation_requests set payload_hash=repeat('9',64) where request_id=$1",
    [request],
  );
  const privileges = await sql(
    `select has_table_privilege(r,'taskfold_private.automation_requests','SELECT,INSERT,UPDATE,DELETE') access from unnest(array['anon','authenticated','service_role']) r`,
  );
  same(privileges.every((x) => !x.access), true);
  for (const role of ["anon", "authenticated", "service_role"]) {
    same(
      await value(
        "select has_function_privilege($1,'taskfold_private.automation_request_begin(uuid,text,uuid,text,uuid,uuid,jsonb,uuid)','EXECUTE')",
        [role],
      ),
      false,
    );
  }
  for (const role of ["anon", "authenticated"]) {
    same(
      await value(
        "select has_function_privilege($1,'public.taskfold_automation_read(uuid,text,text,jsonb)','EXECUTE')",
        [role],
      ),
      false,
    );
  }
  same(
    await value(
      "select has_function_privilege('service_role','public.taskfold_automation_read(uuid,text,text,jsonb)','EXECUTE')",
    ),
    true,
  );

  // Same nonce in another account cannot consume the first account's receipt.
  const newGeneration = (await current()).task_generation;
  await tx(async () => {
    const start = await begin(
      request,
      "update",
      task,
      newGeneration,
      body,
      bKey,
      bHash,
    );
    same(start.replayed, false);
    same(start.account, b);
    await sql("select set_config('request.jwt.claim.sub',$1,true)", [b]);
    const r = await patch(await current(), body.changes);
    await value(
      "select taskfold_private.automation_request_finish($1,$2,$3,$4,null,null)",
      [b, request, newGeneration, r.completion_version],
    );
  });

  // Delegated keys survive native sign-out; their own expiry/account removal do
  // not. These are local fixture clocks/rows, not new live account mutations.
  await sql("delete from auth.sessions where user_id=$1", [a]);
  same((await read("get", { id: inbox })).task.id, inbox);
  await refuses(
    "28000",
    "select public.taskfold_automation_read($1,$2,$3,$4::jsonb)",
    [key, "9".repeat(64), "get", JSON.stringify({ id: inbox })],
  );
  await sql(
    "update taskfold_private.automation_keys set expires_at=clock_timestamp()-interval '1 second' where id=$1",
    [key],
  );
  await refuses(
    "28000",
    "select public.taskfold_automation_read($1,$2,$3,$4::jsonb)",
    [key, hash, "get", JSON.stringify({ id: inbox })],
  );
  await sql(
    "update taskfold_private.automation_keys set expires_at=clock_timestamp()+interval '1 day' where id=$1",
    [key],
  );
  await sql(
    "insert into taskfold_private.account_removal_receipts(token_hash,account_id) values(repeat('8',64),$1)",
    [a],
  );
  await sql(
    "delete from taskfold_private.account_removal_receipts where account_id=$1",
    [a],
  );
  await refuses(
    "28000",
    "select public.taskfold_automation_read($1,$2,$3,$4::jsonb)",
    [key, hash, "get", JSON.stringify({ id: inbox })],
  );
  // Auth deletion is the sole journal-retention boundary; outsider work survives.
  await sql("delete from auth.users where id=$1", [a]);
  same(
    await value(
      "select count(*)::int from taskfold_private.automation_requests where user_id=$1",
      [a],
    ),
    0,
  );
  same((await current(outside)).title, "OUTSIDER PRIVATE TITLE");
  same(
    await value(
      "select count(*)::int from taskfold_private.automation_requests where user_id=$1",
      [b],
    ),
    1,
    "Outsider journal survives another account deletion",
  );
  await sql("delete from auth.users where id in($1,$2)", [b, c]);
  same(
    await value("select count(*)::int from auth.users"),
    0,
    "All owned local fixture identities removed",
  );
  await load("../../supabase/tests/automation_access.sql");
  same(
    await value("select count(*)::int from auth.users"),
    0,
    "Credential fixture rolls back after all candidates",
  );
  console.log(
    `PASS ${checks} local task-read/journal/native-effect assertions. No hosted deployment, real HTTP, concurrency or full task-operation acceptance.`,
  );
} catch (error) {
  console.error(error.message);
  if (error.actual !== undefined) {
    console.error({ actual: error.actual, expected: error.expected });
  }
  if (error.where) console.error(error.where);
  process.exitCode = 1;
} finally {
  await db.close();
}
