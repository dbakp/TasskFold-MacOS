import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import { checkHttpPipeline } from "./automation-http-pipeline.mjs";
import { checkPortableReminders } from "./automation-portable-reminders.mjs";
const db = new PGlite({ extensions: { pgcrypto } });
let checks = 0;
const same = (a, b, n) => {
  assert.deepEqual(a, b, n);
  checks++;
};
const q = async (sql, args = []) => (await db.query(sql, args)).rows;
const v = async (sql, args = []) => Object.values((await q(sql, args))[0])[0];
const load = async (path) =>
  db.exec(await readFile(new URL(path, import.meta.url), "utf8"));
const id = (n) => "f095cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const a = id(1),
  b = id(2),
  c = id(3),
  project = id(31),
  otherProject = id(32),
  foreignProject = id(33),
  section = id(35);
const key = id(21),
  readKey = id(22),
  createKey = id(23),
  completeKey = id(24),
  editKey = id(25),
  deleteKey = id(26);
const hash = "1".repeat(64);
let nonce = 1000;
const body = (target, generation, extra = {}) => ({
  request_id: id(nonce++),
  id: target,
  task_generation: generation,
  time_zone: "UTC",
  ...extra,
});
const get = (target) =>
  v("select public.taskfold_automation_read($1,$2,'get',$3::jsonb)", [
    key,
    hash,
    JSON.stringify({ id: target }),
  ]).then((x) => x.task);
const raw = (target) =>
  v("select to_jsonb(t) from public.tasks t where id=$1", [target]);
const write = (action, body, keyID = key) =>
  v("select public.taskfold_automation_write($1,$2,$3,$4::jsonb)", [
    keyID,
    keyID === key
      ? hash
      : String(Number(keyID.slice(-2))).repeat(64).slice(0, 64),
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
async function create(target, fields = {}, keyID = key) {
  const input = body(target, id(Number(target.slice(-4)) + 10000), {
    fields: { title: "Synthetic task", ...fields },
  });
  const result = await write("create", input, keyID);
  return { input, result, task: await get(target) };
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
    "alter table public.projects add column is_archived boolean not null default false,add column ancestor_archived boolean not null default false,add column color text,add column order_index integer,add column parent_id uuid;create table public.sections(id uuid primary key,project_id uuid references public.projects(id) on delete cascade,name text,order_index integer)",
  );
  const gen = await readFile(
    new URL(
      "../../supabase/migrations/20261006124947_task_generations_and_reminder_eligibility.sql",
      import.meta.url,
    ),
    "utf8",
  );
  const boundary = gen.indexOf("-- The read-only remote activation epoch");
  assert(boundary > 0);
  await db.exec(gen.slice(0, boundary));
  await load(
    "../../supabase/migrations/20261006031648_completion_revision.sql",
  );
  await load(
    "../../supabase/migrations/20261020194217_subtask_structure_review.sql",
  );
  const pref = await readFile(
    new URL(
      "../../supabase/migrations/20261007101832_automatic_reminder_preferences.sql",
      import.meta.url,
    ),
    "utf8",
  );
  await db.exec(pref.slice(0, pref.indexOf("-- Row locking")));
  await db.exec(
    "create table public.reminder_preferences(user_id uuid references auth.users(id) on delete cascade,id text default 'current',settings jsonb not null check(taskfold_private.valid_reminder_preferences(settings)),updated_at timestamptz default now(),primary key(user_id,id))",
  );
  for (
    const file of [
      "20261022212224_automation_access.sql",
      "20261022215836_automation_recurrence_plan.sql",
      "20261022220821_automation_task_access.sql",
      "20261022222726_automation_task_writes.sql",
      "20261022225439_automation_task_mutations.sql",
      "20261023002825_automation_enrollment_cancellation.sql",
      "20261023010559_automation_destinations.sql",
      "20261023011251_automation_portable_reminders.sql",
    ]
  ) await load("../../supabase/migrations/" + file);
  await db.exec(
    "create trigger taskfold_normalize_planned_instant before insert or update on public.tasks for each row execute function taskfold_private.normalize_planned_instant();create trigger taskfold_timestamp before update on public.tasks for each row execute function public.update_completed_at()",
  );
  await q("insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6)", [
    a,
    "mutation-a@example.invalid",
    b,
    "mutation-b@example.invalid",
    c,
    "mutation-c@example.invalid",
  ]);
  await q("insert into public.profiles(user_id) values($1),($2),($3)", [
    a,
    b,
    c,
  ]);
  await q(
    "insert into public.projects(id,user_id,name) values($1,$2,$3),($4,$5,$6),($7,$8,$9)",
    [
      project,
      b,
      "Shared project",
      otherProject,
      a,
      "Destination project",
      foreignProject,
      c,
      "PRIVATE OUTSIDER PROJECT",
    ],
  );
  await q("insert into public.sections(id,project_id,name) values($1,$2,$3)", [
    section,
    project,
    "Shared section",
  ]);
  await q("select set_config('request.jwt.claim.sub',$1,false)", [b]);
  await q(
    "insert into public.project_collaborators(id,project_id,invited_email,invited_by) values($1,$2,$3,$4)",
    [id(51), project, "mutation-a@example.invalid", b],
  );
  await q("select set_config('request.jwt.claim.sub',$1,false)", [a]);
  await q(
    "update public.project_collaborators set status='accepted' where id=$1",
    [id(51)],
  );
  const keys = [
    [key, ["read", "create", "update", "complete", "delete"], hash],
    [readKey, ["read"], "22".repeat(32)],
    [createKey, ["create"], "23".repeat(32)],
    [completeKey, ["complete"], "24".repeat(32)],
    [editKey, ["update"], "25".repeat(32)],
    [deleteKey, ["delete"], "26".repeat(32)],
  ];
  for (const [k, scopes, h] of keys) {
    await q(
      "insert into taskfold_private.automation_keys(id,user_id,name,token_hash,scopes,ttl_days,expires_at) values($1,$2,'Synthetic key',$3,$4,30,clock_timestamp()+interval '30 days')",
      [k, a, h, scopes.map((x) => "tasks:" + x)],
    );
  }
  // An ambient service JWT subject must never become the edit actor.
  await q("select set_config('request.jwt.claim.sub',$1,false)", [c]);
  await db.exec(
    "create table taskfold_private.fixture_actor_trace(actor uuid,task uuid);create function taskfold_private.fixture_trace_actor() returns trigger language plpgsql as $$begin insert into taskfold_private.fixture_actor_trace values(auth.uid(),new.id);return new;end$$;create trigger fixture_trace_actor after insert or update on public.tasks for each row execute function taskfold_private.fixture_trace_actor()",
  );
  await db.exec("set role service_role");
  const first = await create(id(101), {
    project_id: project,
    section_id: section,
    priority: 2,
  });
  same(
    first.task.user_id,
    a,
    "Create derives the task creator from verified key",
  );
  same(first.task.project_id, project);
  same(first.result.replayed, false);
  same((await write("create", first.input)).receipt, first.result.receipt);
  await db.exec("reset role");
  same(
    await v("select current_setting('request.jwt.claim.sub',true)"),
    c,
    "Actor restored",
  );
  same(
    await v(
      "select bool_and(actor=$1) from taskfold_private.fixture_actor_trace",
      [a],
    ),
    true,
    "Native SQL observes only the verified actor",
  );
  same(
    await v("select count(*)::int from public.reminder_preferences"),
    0,
    "Untimed create does not materialize settings",
  );
  same(typeof first.task.revision, "string");
  same(first.task.revision.length, 64);
  const base = await get(id(101));
  await q("update public.tasks set description=$1 where id=$2", [
    "Concurrent remote note",
    base.id,
  ]);
  const edit = body(base.id, base.task_generation, {
    base,
    fields: { title: "Edited title" },
  });
  same((await write("update", edit)).replayed, false);
  same(
    (await get(base.id)).description,
    "Concurrent remote note",
    "Disjoint native merge survives",
  );
  await refuses(
    "PT409",
    () =>
      write(
        "update",
        body(base.id, base.task_generation, {
          base,
          fields: { title: "Conflicting title" },
        }),
      ),
  );
  const newer = await get(base.id);
  same((await write("update", edit)).replayed, true);
  same(
    (await get(base.id)).title,
    newer.title,
    "Replay cannot reapply an edit",
  );
  await refuses(
    "42501",
    () =>
      write(
        "update",
        body(base.id, base.task_generation, {
          base: newer,
          fields: { title: "DENIED" },
        }),
        readKey,
      ),
  );
  // Timed defaults read the supported preference, while future settings stay opaque.
  await q(
    'insert into public.reminder_preferences values($1,\'current\',\'{"version":1,"snooze_minutes":60,"automatic_before_minutes":30}\',now())',
    [a],
  );
  const timed = await create(id(102), {
    due_date: "2026-03-29",
    due_time: "02:30",
    time_zone: "Europe/Copenhagen",
  });
  same(
    new Date(timed.task.scheduled_at).toISOString(),
    "2026-03-29T01:00:00.000Z",
  );
  same(timed.task.reminder_specs[0].offset_minutes, -30);
  await q(
    'update public.reminder_preferences set settings=\'{"version":2,"future":true}\' where user_id=$1',
    [a],
  );
  const future = await create(id(103), {
    due_date: "2026-10-24",
    due_time: "09:00",
    time_zone: "UTC",
  });
  same(future.task.reminder_specs, []);
  same(
    await v(
      "select settings from public.reminder_preferences where user_id=$1",
      [a],
    ),
    { version: 2, future: true },
  );
  // Recurrence complete/reopen/replay uses one stable successor and proper ownership.
  const today = await v(
    "select to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD')",
  );
  const recurring = await create(id(104), {
    project_id: project,
    due_date: today,
    is_recurring: true,
    recurrence_pattern: { type: "daily", count: 3 },
    subtasks: [{ id: "step", title: "Step", completed: false, subtasks: [] }],
  });
  const complete = body(recurring.task.id, recurring.task.task_generation, {
    base: recurring.task,
  });
  const completed = await write("complete", complete, completeKey);
  same(completed.receipt.operation, "complete");
  const child = await get(completed.receipt.successor_id);
  same(child.user_id, a);
  same(child.project_id, project);
  same(child.recurrence_pattern.count, 2);
  same(child.subtasks[0].completed, false);
  const completedParent = await get(recurring.task.id);
  await write(
    "reopen",
    body(completedParent.id, completedParent.task_generation, {
      base: completedParent,
    }),
    completeKey,
  );
  same((await get(completedParent.id)).completed, false);
  same((await write("complete", complete, completeKey)).replayed, true);
  same(
    (await get(completedParent.id)).completed,
    false,
    "Old request cannot repeat a later cycle",
  );
  const beforeSecond = await get(completedParent.id);
  await write(
    "complete",
    body(beforeSecond.id, beforeSecond.task_generation, { base: beforeSecond }),
    completeKey,
  );
  same(
    await v(
      "select count(*)::int from public.tasks where recurrence_parent_id=$1",
      [beforeSecond.id],
    ),
    1,
    "Existing successor suppresses a second creation",
  );
  // Reviewed family deletion requires every child and detects intervening edits.
  const parent = await get(recurring.task.id), freshChild = await get(child.id);
  await refuses(
    "PT409",
    () =>
      write(
        "delete",
        body(parent.id, parent.task_generation, {
          revision: parent.revision,
          descendants: [],
        }),
      ),
  );
  const deletion = body(parent.id, parent.task_generation, {
    revision: parent.revision,
    descendants: [{
      id: freshChild.id,
      task_generation: freshChild.task_generation,
      revision: freshChild.revision,
    }],
  });
  await q("update public.tasks set title=$1 where id=$2", [
    "Changed after review",
    child.id,
  ]);
  await refuses("PT409", () => write("delete", deletion));
  same(
    (await get(parent.id)).id,
    parent.id,
    "Failed family review preserves root",
  );
  const reviewedChild = await get(child.id);
  deletion.descendants[0].revision = reviewedChild.revision;
  const deleted = await write("delete", deletion, deleteKey);
  same(deleted.receipt.deleted, true);
  same(
    await v("select count(*)::int from public.tasks where id=any($1)", [[
      parent.id,
      child.id,
    ]]),
    0,
  );
  same((await write("delete", deletion, deleteKey)).replayed, true);

  // Fixture-only quota clock reset between independent behavioral groups. Real
  // quota boundaries remain exercised by the existing credential suite.
  await q(
    "update taskfold_private.automation_keys set window_started_at=clock_timestamp()-interval '1 minute',window_requests=0 where user_id=$1",
    [a],
  );
  // Directly seeded native creator B, completed by actor A with complete-only key.
  const foreignRoot = id(120), foreignGen = id(10120);
  await q(
    "insert into public.tasks(id,user_id,title,project_id,due_date,is_recurring,recurrence_pattern,task_generation) values($1,$2,$3,$4,$5,true,$6::jsonb,$7)",
    [
      foreignRoot,
      b,
      "Foreign creator recurrence",
      project,
      today,
      JSON.stringify({ type: "daily", count: 2 }),
      foreignGen,
    ],
  );
  const foreignBase = await get(foreignRoot),
    foreignCompletion = body(foreignRoot, foreignGen, { base: foreignBase });
  const foreignDone = await write("complete", foreignCompletion, completeKey);
  same(
    (await get(foreignDone.receipt.successor_id)).user_id,
    a,
    "Shared successor is created by the authorized actor",
  );
  same((await get(foreignRoot)).user_id, b, "Parent creator never changes");
  await q("update public.tasks set project_id=$1 where id=$2", [
    foreignProject,
    foreignDone.receipt.successor_id,
  ]);
  await refuses(
    "PT404",
    () => write("complete", foreignCompletion, completeKey),
  );
  await q("update public.tasks set project_id=$1 where id=$2", [
    project,
    foreignDone.receipt.successor_id,
  ]);
  same(
    (await write("complete", foreignCompletion, completeKey)).replayed,
    true,
  );
  await q("select set_config('request.jwt.claim.sub',$1,false)", [a]);
  await q(
    "update public.project_collaborators set status='pending' where id=$1",
    [id(51)],
  );
  await refuses(
    "PT404",
    () => write("complete", foreignCompletion, completeKey),
  );
  await q(
    "update public.project_collaborators set status='accepted' where id=$1",
    [id(51)],
  );
  await q("select set_config('request.jwt.claim.sub',$1,false)", [c]);
  // Checklist content/structure can change without forging history or erasing
  // omitted child metadata. Checklist progress additionally requires complete.
  const checklist = await create(id(121), {
    subtasks: [{
      id: "step",
      title: "Original step",
      completed: false,
      subtasks: [{
        id: "nested",
        title: "Keep nested",
        completed: false,
        subtasks: [],
      }],
    }],
  });
  const originalNodes = checklist.task.subtasks;
  originalNodes[0].comments = [{
    id: "old-comment",
    text: "Preserve historical comment",
  }];
  originalNodes[0].opaque_future = { keep: true };
  await q("update public.tasks set subtasks=$1::jsonb where id=$2", [
    JSON.stringify(originalNodes),
    checklist.task.id,
  ]);
  const checklistBase = await get(checklist.task.id);
  await write(
    "update",
    body(checklistBase.id, checklistBase.task_generation, {
      base: checklistBase,
      fields: { subtasks: [{ id: "step", title: "Edited step" }] },
    }),
    editKey,
  );
  let savedChecklist = await get(checklistBase.id);
  same(savedChecklist.subtasks[0].subtasks[0].title, "Keep nested");
  same(savedChecklist.subtasks[0].comments, originalNodes[0].comments);
  same(savedChecklist.subtasks[0].opaque_future, { keep: true });
  await refuses(
    "22023",
    () =>
      write(
        "update",
        body(savedChecklist.id, savedChecklist.task_generation, {
          base: savedChecklist,
          fields: {
            subtasks: [{
              id: "step",
              comments: [{ id: "forged", text: "FORGED" }],
            }],
          },
        }),
        editKey,
      ),
  );
  const progress = body(savedChecklist.id, savedChecklist.task_generation, {
    base: savedChecklist,
    fields: { subtasks: [{ id: "step", completed: true }] },
  });
  await refuses("42501", () => write("update", progress, editKey));
  await write("update", progress);
  savedChecklist = await get(savedChecklist.id);
  same(savedChecklist.subtasks[0].completed, true);
  same(
    Number.isFinite(Date.parse(savedChecklist.subtasks[0].completed_at)),
    true,
  );
  await write(
    "update",
    body(savedChecklist.id, savedChecklist.task_generation, {
      base: savedChecklist,
      fields: { subtasks: [{ id: "step", completed: false }] },
    }),
  );
  savedChecklist = await get(savedChecklist.id);
  same(savedChecklist.subtasks[0].completed_at, null);
  await refuses(
    "22023",
    () =>
      write(
        "update",
        body(savedChecklist.id, savedChecklist.task_generation, {
          base: savedChecklist,
          fields: {
            subtasks: [{ id: "step", completed_at: "2000-01-01T00:00:00Z" }],
          },
        }),
      ),
  );
  // Explicit reminder authorship supports portable v1; opaque/private choices
  // remain intact and cannot be silently removed by a legacy-shaped replacement.
  const opaque = {
    version: 99,
    id: id(201),
    kind: "future",
    opaque: { keep: true },
  };
  await q("update public.tasks set reminder_specs=$1::jsonb where id=$2", [
    JSON.stringify([opaque]),
    checklistBase.id,
  ]);
  let reminderBase = await get(checklistBase.id);
  const manual = {
    version: 1,
    id: id(202),
    kind: "relative",
    anchor: "planned",
    offset_minutes: -5,
    channels: ["local"],
    enabled: true,
  };
  await write(
    "update",
    body(reminderBase.id, reminderBase.task_generation, {
      base: reminderBase,
      fields: { reminder_specs: [opaque, manual] },
    }),
  );
  reminderBase = await get(reminderBase.id);
  same(reminderBase.reminder_specs, [opaque, manual]);
  await refuses(
    "22023",
    () =>
      write(
        "update",
        body(reminderBase.id, reminderBase.task_generation, {
          base: reminderBase,
          fields: { reminder_specs: [manual] },
        }),
      ),
  );
  // A private linked task is preserved even if an administrator supplies its
  // opaque revision to this deliberately unauthorized deletion attempt.
  const family = await create(id(122), { project_id: project });
  const hidden = id(123), hiddenGen = id(10123);
  await q(
    "insert into public.tasks(id,user_id,title,project_id,task_generation,recurrence_parent_id) values($1,$2,$3,$4,$5,$6)",
    [
      hidden,
      c,
      "PRIVATE LINKED TASK",
      foreignProject,
      hiddenGen,
      family.task.id,
    ],
  );
  const hiddenRevision = await v(
    "select taskfold_private.automation_task_revision(t) from public.tasks t where id=$1",
    [hidden],
  );
  await refuses(
    "PT404",
    () =>
      write(
        "delete",
        body(family.task.id, family.task.task_generation, {
          revision: family.task.revision,
          descendants: [{
            id: hidden,
            task_generation: hiddenGen,
            revision: hiddenRevision,
          }],
        }),
      ),
  );
  same((await raw(hidden)).title, "PRIVATE LINKED TASK");
  same((await get(family.task.id)).id, family.task.id);
  // Moving clears inherited assignments/section before explicit reassignment,
  // and archived projects cannot become a back door for writes.
  const moving = await create(id(124), {
    project_id: project,
    section_id: section,
    assigned_to: b,
    subtasks: [{
      id: "assigned-step",
      title: "Assigned",
      assigned_to: b,
      completed: false,
      subtasks: [],
    }],
  });
  await write(
    "update",
    body(moving.task.id, moving.task.task_generation, {
      base: moving.task,
      fields: { project_id: otherProject, assigned_to: a },
    }),
  );
  const moved = await get(moving.task.id);
  same(moved.project_id, otherProject);
  same(moved.section_id, null);
  same(moved.assigned_to, a);
  same(moved.subtasks[0].assigned_to, null);
  await q("update public.projects set is_archived=true where id=$1", [
    otherProject,
  ]);
  await refuses(
    "PT409",
    () =>
      write(
        "update",
        body(moved.id, moved.task_generation, {
          base: moved,
          fields: { title: "DENIED ARCHIVE" },
        }),
      ),
  );
  await q("update public.projects set is_archived=false where id=$1", [
    otherProject,
  ]);
  await q(
    "update taskfold_private.automation_keys set window_started_at=clock_timestamp()-interval '1 minute',window_requests=0 where user_id=$1",
    [a],
  );
  // Supported native formatting capacity is readable as well as writable.
  const large = await create(id(125), { description: "x".repeat(512000) });
  same(large.task.description.length, 512000);
  // New nonprojected fields affect the opaque version without becoming readable
  // or exposing a plain dictionary-guessable row digest.
  await db.exec(
    "alter table public.tasks add column fixture_private_value text default 'PRIVATE FUTURE VALUE'",
  );
  const privateVersion = await get(first.task.id);
  same(JSON.stringify(privateVersion).includes("PRIVATE FUTURE VALUE"), false);
  const plainDigest = await v(
    "select encode(extensions.digest(to_jsonb(t)::text,'sha256'),'hex') from public.tasks t where id=$1",
    [first.task.id],
  );
  same(privateVersion.revision === plainDigest, false);
  await q("update public.tasks set fixture_private_value=$1 where id=$2", [
    "DIFFERENT PRIVATE VALUE",
    first.task.id,
  ]);
  same((await get(first.task.id)).revision === privateVersion.revision, false);
  await db.exec("alter table public.tasks drop column fixture_private_value");
  // Whole-row revisions are opaque and connection-zone independent.
  const exact = await get(first.task.id);
  await db.exec("set time zone 'Pacific/Auckland'");
  same((await get(exact.id)).revision, exact.revision);
  // Unreviewed/readonly fields fail before effects and never retain a pending claim.
  for (
    const fields of [
      { user_id: b },
      { completed: true },
      { comments: [{ text: "FORGED" }] },
      { priority: 0 },
      { priority: 2.5 },
      { duration_minutes: 0 },
      { due_date: "2026-02-30" },
      { time_zone: "Mars/Nope" },
      { title: "" },
    ]
  ) {
    await refuses("22023", () =>
      write(
        "update",
        body(exact.id, exact.task_generation, { base: exact, fields }),
      ));
  }

  await q(
    "update taskfold_private.automation_keys set revoked_at=clock_timestamp() where id=$1",
    [createKey],
  );
  await refuses("28000", () => create(id(126), {}, createKey));
  same(
    await v("select count(*)::int from public.tasks where id=$1", [id(126)]),
    0,
  );
  same(
    await v(
      "select count(*)::int from taskfold_private.automation_requests where applied_at is null",
    ),
    0,
  );
  same(
    await v(
      "select has_function_privilege('authenticated','public.taskfold_automation_write(uuid,text,text,jsonb)','EXECUTE')",
    ),
    false,
  );
  same(
    await v(
      "select has_table_privilege('service_role','taskfold_private.automation_revision_secret','SELECT')",
    ),
    false,
  );
  const portable = await checkPortableReminders(db, a, id);
  console.log(
    `PASS ${portable.checks} portable reminder assertions including ${portable.goldenCases} native-reader goldens.`,
  );
  const httpChecks = await checkHttpPipeline(db, a, id);
  same(httpChecks >= 18, true, "Actual local HTTP/SQL pipeline checks");
  await q("delete from auth.users where id in($1,$2,$3)", [a, b, c]);
  same(await v("select count(*)::int from auth.users"), 0);
  console.log(
    `PASS ${checks} actual local task-mutation assertions. ${httpChecks} local HTTP-to-handler-to-SQL assertions also pass; no hosted Auth/TLS, cross-connection race or native UI acceptance.`,
  );
} catch (e) {
  console.error(e.message);
  if (e.actual !== undefined) {
    console.error({ actual: e.actual, expected: e.expected });
  }
  if (e.where) console.error(e.where);
  process.exitCode = 1;
} finally {
  await db.close();
}
