import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadWorkflowRunSchema } from "./team-workflow-run-schema.mjs";
import { loadChildTaskRecordsSchema } from "./child-task-records-schema.mjs";

// Runs the generated migration against an owned synthetic database; never deploys.
const candidate = await readFile(new URL("../../supabase/migrations/20261029194600_child_task_field_resolution.sql", import.meta.url), "utf8");
const report = { checks: {}, candidateSHA256: createHash("sha256").update(candidate).digest("hex"), deployed: false };
const json = value => lit(JSON.stringify(value)) + "::jsonb";
const check = (name, actual, expected) => { assert.deepEqual(actual, expected, name); report.checks[name] = true; };
let pg;
try {
  report.stage = "engine preflight";
  // Bound the preflight with SIGKILL: a wedged Docker client can ignore the
  // ordinary fixture's SIGTERM timeout before any container exists.
  await promisify(execFile)("docker", ["info", "--format", "{{.ServerVersion}}"], { timeout: 5000, killSignal: "SIGKILL" });
  report.stage = "disposable database fixture";
  pg = await createPostgresFixture({ advisors: true });
  await loadWorkflowRunSchema(pg.raw, { taskTypes: true });
  await loadChildTaskRecordsSchema(pg.raw);
  for (const migration of ["20261029001127_child_task_record_reads.sql", "20261029005723_child_task_field_edits.sql"]) {
    await pg.raw(await readFile(new URL("../../supabase/migrations/" + migration, import.meta.url), "utf8"));
  }
  report.baselineAdvisors = await pg.advisors();
  await pg.raw(candidate);
  if (process.env.TASKFOLD_FIELD_NATIVE_SQL) {
    const nativeField = await readFile(process.env.TASKFOLD_FIELD_NATIVE_SQL, "utf8");
    await pg.raw(nativeField);
    report.nativeFieldMigrationSHA256 = createHash("sha256").update(nativeField).digest("hex");
  }
  const people = [0, 1].map(() => ({ id: randomUUID(), session: randomUUID() }));
  for (const p of people) await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(p.id)},${lit(p.id + "@example.invalid")},now());insert into public.profiles(user_id) values(${lit(p.id)});insert into auth.sessions(id,user_id) values(${lit(p.session)},${lit(p.id)});`);
  const owner = people[0], other = people[1], task = randomUUID();
  const source = [{ id: "child", title: "Original", description: "Original notes", priority: 4, completed: false, completed_at: null, subtasks: [], taskfold_completion_v1: { epoch: randomUUID(), version: 0 }, comments: [], attachments: [], future: { keep: true } }];
  await pg.raw(`insert into public.tasks(id,user_id,title,subtasks) values(${lit(task)},${lit(owner.id)},'Synthetic resolution root',${json(source)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)};`);
  const row = () => pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(task)}`);
  const node = () => pg.scalar(`select to_jsonb(n) from taskfold_private.child_task_records n where task_id=${lit(task)} and node_key='child'`);
  const command = async title => {
    const r = await row(), n = await node();
    return { protocol: 1, account: owner.id, request_id: randomUUID(), task_id: task, task_generation: r.task_generation, project_id: r.project_id, node_key: "child", incarnation: n.incarnation, revision: n.revision, changes: { title } };
  };
  const claims = (p, session = p.session) => `set local role authenticated;set local request.jwt.claim.sub=${lit(p.id)};set local request.jwt.claims=${lit(JSON.stringify({ sub: p.id, session_id: session }))};`;
  const run = (body, { close = false, who = owner, session = who.session, app = "child-resolution" } = {}) => pg.scalar(`begin;set application_name=${lit(app)};create temp table result(value jsonb,code text) on commit drop;grant all on result to authenticated;${claims(who, session)}do $op$begin begin insert into result values(public.${close ? "taskfold_close_child_task_edit" : "taskfold_edit_child_task"}(${json(body)}),null);exception when others then insert into result values(null,sqlstate);end;end$op$;select jsonb_build_object('value',value,'code',code) from result;commit;`);
  const original = await command("Never apply closed original"), before = await row();
  check("edits remain disabled", (await run(original)).code, "PT503");
  const first = await run(original, { close: true });
  check("closure works with edit gate off", [first.code, first.value.outcome, first.value.receipt], [null, "closed", null]);
  check("closure does not change root", await row(), before);
  check("lost close reply retry is identical", (await run(original, { close: true })).value, first.value);
  check("changed body cannot reuse closure identity", (await run({ ...original, changes: { title: "Different intent" } }, { close: true })).code, "PT409");
  await pg.raw("update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true");
  check("closed original cannot apply after gate opens", (await run(original)).code, "PT410");
  const applied = await command("Applied before close"), edit = await run(applied);
  check("fresh identity can apply", edit.code, null);
  const closedApplied = await run(applied, { close: true });
  check("close recovers applied result", [closedApplied.code, closedApplied.value.outcome], [null, "applied"]);
  check("recovered receipt keeps original revision", closedApplied.value.receipt.revision, edit.value.revision);
  check("close does not undo applied value", (await row()).subtasks[0].title, "Applied before close");
  check("applied request has no tombstone", await pg.scalar(`select count(*) from taskfold_private.child_task_edit_closures where actor_id=${lit(owner.id)} and request_id=${lit(applied.request_id)}`), 0);
  check("wrong intended account refused", (await run(original, { close: true, who: other })).code, "42501");
  check("missing session refused", (await run(original, { close: true, session: null })).code, "28000");
  for (const [name, patch] of [["unknown envelope", { unknown: true }], ["malformed identity", { node_key: "" }], ["completion smuggling", { changes: { completed: true } }], ["oversized body", { changes: { title: "x".repeat(130000) } }]]) {
    check(name, (await run({ ...original, ...patch, request_id: randomUUID() }, { close: true })).code, "22023");
  }
  const isolated = await command("Account isolated");
  check("another actor may close only its own identity", (await run({ ...isolated, account: other.id }, { close: true, who: other })).value.outcome, "closed");
  check("other actor closure does not poison owner request", (await run(isolated)).code, null);
  // Real lock graphs prove both race orderings, rather than a sleeping client.
  for (const closeFirst of [false, true]) {
    const c = await command(closeFirst ? "Must stay unapplied" : "Committed before closure");
    const hold = await pg.hold(`${claims(owner)}select public.${closeFirst ? "taskfold_close_child_task_edit" : "taskfold_edit_child_task"}(${json(c)});`);
    let pending;
    try {
      const app = closeFirst ? "resolution-edit-wait" : "resolution-close-wait";
      pending = run(c, { close: !closeFirst, app });
      const wait = await pg.waitForLock(app, hold.pid);
      report[closeFirst ? "closeFirstGraph" : "editFirstGraph"] = { holder: hold.pid, wait };
      check(app + " blocks on actor owner", wait.blockers.includes(hold.pid), true);
      await hold.release("commit");
      const result = await pending;
      check(closeFirst ? "close wins against waiting edit" : "edit wins against waiting close", closeFirst ? result.code : result.value.outcome, closeFirst ? "PT410" : "applied");
    } finally { await hold.release("rollback"); if (pending) await pending; }
  }
  const removed = await command("Preserved request after task deletion");
  await pg.raw(`delete from public.tasks where id=${lit(task)}`);
  check("closure after task deletion returns no content", (await run(removed, { close: true })).value.outcome, "closed");
  check("applied receipt survives task deletion", (await run(applied, { close: true })).value.outcome, "applied");
  const direct = await pg.value("(select to_jsonb(count(*)) from taskfold_private.child_task_edit_closures)", { role: "service_role" });
  check("direct table access denied", direct.code, "42501");
  await pg.raw(`insert into taskfold_private.child_task_edit_closures(actor_id,request_id,fingerprint) select ${lit(owner.id)},gen_random_uuid(),repeat('0',64) from generate_series(1,2000);`);
  check("known close bypasses new closure quota", (await run(original, { close: true })).value.outcome, "closed");
  check("applied status bypasses closure quota", (await run(applied, { close: true })).value.outcome, "applied");
  check("new closure quota refuses safely", (await run({ ...removed, request_id: randomUUID() }, { close: true })).code, "PT429");
  check("anonymous close execute is denied", await pg.scalar("select to_jsonb(has_function_privilege('anon','public.taskfold_close_child_task_edit(jsonb)','execute'))"), false);
  check("public close uses invoker permissions", await pg.scalar("select to_jsonb(not prosecdef) from pg_proc where oid='public.taskfold_close_child_task_edit(jsonb)'::regprocedure"), true);
  check("closure rows have RLS", await pg.scalar("select to_jsonb(relrowsecurity) from pg_class where oid='taskfold_private.child_task_edit_closures'::regclass"), true);
  check("authenticated direct table access is denied", await pg.scalar("select to_jsonb(has_table_privilege('authenticated','taskfold_private.child_task_edit_closures','select,insert,update,delete'))"), false);
  check("private close has fixed search path", await pg.scalar("select to_jsonb('search_path=\"\"'=any(proconfig)) from pg_proc where oid='taskfold_private.close_child_task_edit(jsonb)'::regprocedure"), true);
  report.finalAdvisors = await pg.advisors();
  const priorFindings = new Set(report.baselineAdvisors.result.map(x => x.cache_key));
  check("no added advisor findings", report.finalAdvisors.result.filter(x => !priorFindings.has(x.cache_key)), []);
  report.passed = true;
} catch (error) {
  report.passed = false; report.error = { name: error.name, code: error.code ?? null, signal: error.signal ?? null, message: error.message };
  throw error;
} finally {
  if (pg) report.containerRemoved = await pg.close();
  await writeFile(process.argv[2] ?? "/tmp/taskfold-child-resolution-database.json", JSON.stringify(report, null, 2) + "\n");
}
