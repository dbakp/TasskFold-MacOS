import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
const db = new PGlite({ extensions: { pgcrypto } });
let checks = 0;
const same = (a, b, label) => {
  assert.deepEqual(a, b, label);
  checks++;
};
const sql = async (query, args = []) => (await db.query(query, args)).rows;
const value = async (query, args = []) =>
  Object.values((await sql(query, args))[0])[0];
const load = async (name) =>
  db.exec(await readFile(new URL(name, import.meta.url), "utf8"));
const stamp = (value) => value === null ? null : new Date(value).toISOString();
function normalized(value, key = "") {
  if (Array.isArray(value)) return value.map((v) => normalized(v));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, normalized(v, k)]),
    );
  }
  if (
    typeof value === "string" &&
    ["created_at", "completed_at", "scheduled_at", "notification_sent_at"]
      .includes(key) &&
    Number.isFinite(Date.parse(value))
  ) return stamp(value);
  return value;
}
const uuid = (n) => "f094cafe-0000-4000-8000-" + String(n).padStart(12, "0");
async function refuses(code, query, args = []) {
  let caught = false;
  try {
    await db.query(query, args);
  } catch (e) {
    same(e.code, code, e.message);
    caught = true;
  }
  same(caught, true, "Expected refusal");
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
  await load(
    "../../supabase/migrations/20261022215836_automation_recurrence_plan.sql",
  );
  await load(
    "../../supabase/migrations/20261022222726_automation_task_writes.sql",
  );
  await db.exec(
    "create trigger taskfold_normalize_planned_instant before insert or update on public.tasks for each row execute function taskfold_private.normalize_planned_instant()",
  );
  const fixture = JSON.parse(
    await readFile(
      new URL(
        "../../TaskfoldTests/Fixtures/automation-write-semantics.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  same(
    fixture.wall_times.length + fixture.automatic_reminders.length +
      fixture.successors.length,
    49,
  );
  for (const row of fixture.wall_times) {
    same(
      stamp(
        await value(
          "select taskfold_private.automation_wall_start($1::jsonb,$2)",
          [JSON.stringify(row.task), row.input_zone],
        ),
      ),
      row.expected === null ? null : stamp(row.expected),
      row.name,
    );
  }
  for (const row of fixture.automatic_reminders) {
    same(
      normalized(
        await value(
          "select taskfold_private.automation_automatic_reminder($1::jsonb,$2::jsonb,$3,$4)",
          [
            JSON.stringify(row.task),
            row.previous === null ? null : JSON.stringify(row.previous),
            row.minutes,
            row.input_zone,
          ],
        ),
      ),
      row.expected,
      row.name,
    );
  }
  for (const row of fixture.successors) {
    same(
      normalized(
        await value(
          "select taskfold_private.automation_successor($1::jsonb,$2,$3,$4,$5,$6)",
          [
            JSON.stringify(row.task),
            row.account,
            row.completed_at,
            row.input_zone,
            row.action,
            row.generation,
          ],
        ),
      ),
      row.expected,
      row.name,
    );
  }
  // The connection's display zone must not affect explicit native clocks/series.
  await db.exec("set time zone 'Pacific/Auckland'");
  for (const row of fixture.successors.filter((x) => x.expected !== null)) {
    same(
      normalized(
        await value(
          "select taskfold_private.automation_successor($1::jsonb,$2,$3,$4,$5,$6)",
          [
            JSON.stringify(row.task),
            row.account,
            row.completed_at,
            row.input_zone,
            row.action,
            row.generation,
          ],
        ),
      ),
      row.expected,
      row.name + " server-zone independence",
    );
  }
  const actor = uuid(1), creator = uuid(2), project = uuid(31);
  await sql("insert into auth.users(id,email) values($1,$2),($3,$4)", [
    actor,
    "successor-a@example.invalid",
    creator,
    "successor-b@example.invalid",
  ]);
  await sql("insert into public.profiles(user_id) values($1),($2)", [
    actor,
    creator,
  ]);
  await sql("insert into public.projects(id,user_id,name) values($1,$2,$3)", [
    project,
    creator,
    "Synthetic recurrence workshop",
  ]);
  await sql("select set_config('request.jwt.claim.sub',$1,false)", [creator]);
  await sql(
    "insert into public.project_collaborators(id,project_id,invited_email,invited_by) values($1,$2,$3,$4)",
    [uuid(51), project, "successor-a@example.invalid", creator],
  );
  await sql("select set_config('request.jwt.claim.sub',$1,false)", [actor]);
  await sql(
    "update public.project_collaborators set status='accepted' where id=$1",
    [uuid(51)],
  );
  // Actual native INSERT policy distinguishes the rejected old creator copy from
  // the acting collaborator's permitted new occurrence. Both share one project.
  const rich = fixture.successors.find((x) => x.name === "shared-rich");
  await sql(
    "insert into public.tasks select (jsonb_populate_record(null::public.tasks,$1::jsonb)).*",
    [JSON.stringify(rich.task)],
  );
  const result = await value(
    "select taskfold_private.automation_successor($1::jsonb,$2,$3,$4,$5,$6)",
    [
      JSON.stringify(rich.task),
      actor,
      rich.completed_at,
      rich.input_zone,
      rich.action,
      rich.generation,
    ],
  );
  await db.exec("set role authenticated");
  await refuses(
    "42501",
    "insert into public.tasks select (jsonb_populate_record(null::public.tasks,$1::jsonb)).*",
    [JSON.stringify({ ...result, user_id: creator })],
  );
  await sql(
    "insert into public.tasks select (jsonb_populate_record(null::public.tasks,$1::jsonb)).*",
    [JSON.stringify(result)],
  );
  same(
    await value("select user_id from public.tasks where id=$1", [result.id]),
    actor,
    "Shared successor INSERT belongs to the acting account",
  );
  same(
    await value("select user_id from public.tasks where id=$1", [rich.task.id]),
    creator,
    "Original task creator is preserved",
  );
  // Exercise the trigger under native authenticated DML, not just postgres. Pure
  // time helpers need their narrow grants; successor helpers remain uncallable.
  let n = 200;
  const clockIDs = new Map();
  for (const row of fixture.wall_times) {
    if (row.name === "invalid-zone") continue;
    const t = row.task;
    const clockID = uuid(n++);
    clockIDs.set(row.name, clockID);
    const instant = await value(
      "insert into public.tasks(id,user_id,title,due_date,due_time,time_zone,scheduled_at) values($1,$2,$3,$4::date,$5::time,$6,$7::timestamptz) returning scheduled_at",
      [
        clockID,
        actor,
        "Synthetic clock " + row.name,
        t.due_date,
        t.due_time,
        t.time_zone ?? null,
        t.scheduled_at ?? null,
      ],
    );
    same(
      stamp(instant),
      t.time_zone ? row.expected === null ? null : stamp(row.expected) : null,
      "Native trigger " + row.name,
    );
  }
  const gap = clockIDs.get("copenhagen-gap-first-valid");
  const preserved = await value(
    "update public.tasks set title=$1 where id=$2 returning scheduled_at",
    ["Unrelated title edit", gap],
  );
  same(
    stamp(preserved),
    stamp("2026-03-29T01:00:00Z"),
    "Gap normalization remains at first valid minute after unrelated edit",
  );
  const fold = clockIDs.get("stale-saved-instant");
  const moved = await value(
    "update public.tasks set due_date='2026-10-26' where id=$1 returning scheduled_at",
    [fold],
  );
  same(
    stamp(moved),
    stamp("2026-10-26T01:30:00Z"),
    "Moving a date rebuilds the old instant",
  );
  await refuses(
    "42501",
    "select taskfold_private.automation_successor($1::jsonb,$2,$3,$4,$5,$6)",
    [
      JSON.stringify(rich.task),
      actor,
      rich.completed_at,
      rich.input_zone,
      rich.action,
      rich.generation,
    ],
  );
  await db.exec("reset role");
  same(
    await value(
      "select has_function_privilege('authenticated','taskfold_private.automation_wall_start(jsonb,text)','EXECUTE')",
    ),
    true,
  );
  same(
    await value(
      "select has_function_privilege('anon','taskfold_private.automation_wall_start(jsonb,text)','EXECUTE')",
    ),
    false,
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    same(
      await value(
        "select has_function_privilege($1,'taskfold_private.automation_successor(jsonb,uuid,timestamptz,text,uuid,uuid)','EXECUTE')",
        [role],
      ),
      false,
    );
  }
  await sql("delete from auth.users where id in($1,$2)", [actor, creator]);
  same(await value("select count(*)::int from auth.users"), 0);
  console.log(
    `PASS ${checks} local write-semantics assertions, 49 native-shared golden cases, authenticated INSERT/normalization and fixture cleanup. No hosted deployment, complete mutation RPC or Simulator acceptance.`,
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
