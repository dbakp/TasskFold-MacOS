import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadWorkflowRunSchema } from "./team-workflow-run-schema.mjs";
import { loadChildTaskRecordsSchema } from "./child-task-records-schema.mjs";
const candidate = await readFile(process.env.TASKFOLD_COMPLETION_RESOLUTION_SQL ?? new URL("../../supabase/migrations/20261029215232_child_task_completion_resolution.sql", import.meta.url), "utf8");
const report = { checks: {}, candidateSHA256: createHash("sha256").update(candidate).digest("hex"), deployed: false };
const check = (name, actual, expected) => { assert.deepEqual(actual, expected, name); report.checks[name] = true; };
const json = value => lit(JSON.stringify(value)) + "::jsonb";
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  report.stage = "actual task/child history schema";
  process.env.TASKFOLD_TEST_NODE_ADOPTION = "0"; process.env.TASKFOLD_TEST_HISTORY_CUSTODY = "0";
  await loadWorkflowRunSchema(pg.raw, { taskTypes: true });
  for (const file of ["20261026095807_task_node_activity_history.sql", "20261026104450_task_activity_root_context.sql", "20261026113556_task_node_activity_custody.sql", "20261026121332_task_node_project_adoption_review.sql", "20261026122805_reviewed_history_custody.sql"]) await pg.raw(await readFile(new URL("../../supabase/migrations/" + file, import.meta.url), "utf8"));
  await loadChildTaskRecordsSchema(pg.raw);
  for (const file of ["20261029001127_child_task_record_reads.sql", "20261029005723_child_task_field_edits.sql", "20261029194600_child_task_field_resolution.sql", "20261029211038_child_task_completion_commands.sql"]) await pg.raw(await readFile(new URL("../../supabase/migrations/" + file, import.meta.url), "utf8"));
  report.baselineAdvisors = await pg.advisors();
  report.stage = "direct resolution SQL";
  const schema = await pg.scalar(`create temp table schema_result(code text,reason text);do $load$begin begin execute ${lit(candidate)};insert into schema_result values(null,null);exception when others then insert into schema_result values(sqlstate,sqlerrm);end;end$load$;select to_jsonb(r) from schema_result r;drop table schema_result`);
  if (schema.code) throw new Error(schema.code + ": " + schema.reason);
  const people = Object.fromEntries(["owner", "editor", "other"].map(key => [key, { id: randomUUID(), session: randomUUID() }]));
  for (const u of Object.values(people)) await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit(u.id + "@example.invalid")},now());insert into public.profiles(user_id) values(${lit(u.id)});insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});`);
  const task = randomUUID(), owner = people.owner;
  const source = [{ id: "child", title: "Synthetic closure task", completed: false, completed_at: null, subtasks: [], taskfold_completion_v1: { epoch: randomUUID(), version: 0 }, future: { keep: true } }];
  await pg.raw(`insert into public.tasks(id,user_id,title,subtasks) values(${lit(task)},${lit(owner.id)},'Synthetic closure root',${json(source)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)}`);
  const row = (id = task) => pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(id)}`);
  const history = (id = task) => pg.scalar(`select coalesce(jsonb_agg(to_jsonb(a) order by sequence),'[]') from public.task_node_activity a where task_id=${lit(id)}`);
  const command = async ({ id = task, who = "owner", action = "complete", undo = null } = {}) => {
    const r = await row(id), n = await pg.scalar(`select to_jsonb(n) from taskfold_private.child_task_records n where task_id=${lit(id)} and node_key='child'`);
    const baseline = Object.fromEntries(Object.entries(n.fields).filter(([k]) => ["completed", "completed_at", "is_heading", "taskfold_completion_v1"].includes(k)));
    return { protocol: 1, account: people[who].id, request_id: randomUUID(), task_id: id, task_generation: r.task_generation, project_id: r.project_id, node_key: "child", incarnation: n.incarnation, revision: n.revision, action, ...(action === "undo" ? { undo_of: undo } : { baseline }) };
  };
  const claims = (who = "owner", session = people[who].session) => `set local role authenticated;set local request.jwt.claim.sub=${lit(people[who].id)};set local request.jwt.claims=${lit(JSON.stringify({ sub: people[who].id, session_id: session }))};`;
  const fn = close => close ? "public.taskfold_close_child_completion" : "public.taskfold_complete_child_task";
  const run = (body, { close = false, who = "owner", session = people[who].session, method = fn(close), operation = null, app = "completion-resolution" } = {}) => pg.scalar(`begin;set application_name=${lit(app)};create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated;${claims(who, session)}do $op$begin begin insert into result values(${method}(${operation ? lit(operation) + "," : ""}${json(body)}),null,null);exception when others then insert into result values(null,sqlstate,left(sqlerrm,180));end;end$op$;select to_jsonb(r) from result r;commit;`);
  const c = await command(), initial = await row(), events = await history();
  report.stage = "terminal closure and gate-independent metadata";
  const first = await run(c, { close: true }); report.fixtureClosedCommand = c; report.fixtureClosed = first;
  check("closure with all feature gates disabled", [first.code, first.value?.outcome, first.value?.receipt], [null, "closed", null]);
  check("closure never changes task or history", [await row(), await history()], [initial, events]);
  check("lost closure reply exact retry", (await run(c, { close: true })).value, first.value);
  check("changed body cannot reuse closed nonce", (await run({ ...c, revision: c.revision + 1 }, { close: true })).code, "PT409");
  await pg.raw("update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true");
  check("closed request never applies", (await run(c)).code, "PT410");
  const fresh = await command(), applied = await run(fresh);
  check("fresh completion still works", applied.code, null);
  const known = await run(fresh, { close: true }); report.fixtureAppliedCommand = fresh; report.fixtureApplied = known;
  check("resolution recovers applied original receipt", [known.code, known.value?.outcome, known.value?.receipt?.revision], [null, "applied", applied.value?.revision]);
  const undo = await command({ action: "undo", undo: fresh.request_id });
  check("Undo completion still works", (await run(undo)).code, null);
  check("Undo resolution recovers exact applied result", (await run(undo, { close: true })).value?.receipt?.action, "undo");
  check("applied originals have no closure tombstone", await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.child_task_completion_closures where actor_id=${lit(owner.id)} and request_id=${lit(fresh.request_id)}`), 0);
  const unattemptedUndo = await command({ action: "undo", undo: fresh.request_id });
  check("unattempted Undo can be closed without task change", (await run(unattemptedUndo, { close: true })).value?.outcome, "closed");
  check("closed Undo cannot later apply", (await run(unattemptedUndo)).code, "PT410");
  for (const [name, patch] of [["unknown envelope", { extra: true }], ["tree smuggling", { subtasks: [] }], ["invalid baseline", { baseline: { completed: null } }], ["invalid identity", { incarnation: "bad" }], ["oversized metadata", { node_key: "x".repeat(4200) }]]) check(name, (await run({ ...await command(), ...patch }, { close: true })).code, "22023");
  check("intended account fence", (await run(c, { close: true, who: "other" })).code, "42501");
  check("missing live session denied", (await run(c, { close: true, session: null })).code, "28000");
  const isolated = await command();
  check("other actor owns a separate closure namespace", (await run({ ...isolated, account: people.other.id }, { close: true, who: "other" })).value?.outcome, "closed");
  check("other actor cannot poison owner completion", (await run(isolated)).code, null);
  check("owner reopen after isolated complete", (await run(await command({ action: "reopen" }))).code, null);
  report.stage = "real completion and closure lock races";
  for (const closeFirst of [false, true]) {
    const body = await command();
    const hold = await pg.hold(`${claims()}select ${fn(closeFirst)}(${json(body)});`);
    let pending;
    try {
      const app = closeFirst ? "completion-waits-for-close" : "close-waits-for-completion";
      pending = run(body, { close: !closeFirst, app });
      const wait = await pg.waitForLock(app, hold.pid);
      check(app + " reaches actual actor lock", wait.blockers.includes(hold.pid), true);
      await hold.release("commit");
      const result = await pending;
      check(closeFirst ? "closure wins; waiting completion refused" : "completion wins; waiting closure returns applied", closeFirst ? result.code : result.value?.outcome, closeFirst ? "PT410" : "applied");
    } finally { await hold.release("rollback"); if (pending) await pending; }
    if (!closeFirst) check("race cleanup reopen", (await run(await command({ action: "reopen" }))).code, null);
  }
  report.stage = "field nonce barriers";
  const fieldBody = { ...c, changes: { title: "Never apply this field change" } }; delete fieldBody.action; delete fieldBody.baseline;
  check("closed completion cannot become field edit", (await run(fieldBody, { method: "public.taskfold_edit_child_task" })).code, "PT410");
  check("closed completion cannot become field closure", (await run(fieldBody, { method: "public.taskfold_close_child_task_edit" })).code, "PT410");
  fieldBody.request_id = randomUUID();
  check("field closure still works", (await run(fieldBody, { method: "public.taskfold_close_child_task_edit" })).code, null);
  check("field nonce cannot become completion closure", (await run({ ...await command(), request_id: fieldBody.request_id }, { close: true })).code, "PT409");
  report.stage = "ordinary team command coexistence and late writers";
  const team = randomUUID(), project = randomUUID(), tt = randomUUID();
  await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'Synthetic closure team');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin'),(${lit(team)},${lit(people.editor.id)},'member');insert into public.projects(id,user_id,name) values(${lit(project)},${lit(owner.id)},'Synthetic team closure project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(project)},${lit(team)},'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(project)},${lit(team)},${lit(people.editor.id)},'editor');insert into public.tasks(id,user_id,project_id,title,subtasks) values(${lit(tt)},${lit(owner.id)},${lit(project)},'Synthetic team original title',${json(source)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(tt)};update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true`);
  const legacy = async body => ({ team_id: team, project_id: project, task_id: tt, task_generation: (await row(tt)).task_generation, request_id: body.request_id, base: await row(tt), changes: { title: "Synthetic ordinary team edit " + body.request_id } });
  const teamDone = await command({ id: tt, who: "editor" }), teamApplied = await run(teamDone, { who: "editor" });
  check("team completion still admitted", teamApplied.code, null);
  await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(people.editor.id)}`);
  check("own applied metadata after role loss", (await run(teamDone, { close: true, who: "editor" })).value?.outcome, "applied");
  await pg.raw("update taskfold_private.child_task_record_config set reads_enabled=false,edits_enabled=false,completions_enabled=false");
  check("own applied metadata after gates disabled", (await run(teamDone, { close: true, who: "editor" })).value?.receipt?.revision, teamApplied.value?.revision);
  await pg.raw("update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true");
  const otherCommand = await command({ id: tt, action: "reopen" }), ordinary = await legacy(otherCommand);
  const oldWriter = await pg.hold(`${claims()}select public.taskfold_edit_team_task(${json(ordinary)});`);
  try { check("closure never blocks behind late team receipt", (await run(otherCommand, { close: true })).code, "55P03"); await oldWriter.release("commit"); }
  finally { await oldWriter.release("rollback"); }
  check("committed team nonce cannot be closed as completion", (await run(otherCommand, { close: true })).code, "PT409");
  const closeThenOld = await command({ id: tt, action: "reopen" }), oldBody = await legacy(closeThenOld), teamBefore = await row(tt), teamHistory = await history(tt);
  const closeHold = await pg.hold(`${claims()}select public.taskfold_close_child_completion(${json(closeThenOld)});`);
  try {
    check("team late insert refuses uncommitted decision nonblocking", (await run(oldBody, { method: "public.taskfold_edit_team_task" })).code, "55P03");
    check("busy team insert rolls back all root work", [await row(tt), await history(tt)], [teamBefore, teamHistory]);
    await closeHold.release("commit");
  } finally { await closeHold.release("rollback"); }
  check("team late insert refuses committed closure", (await run(oldBody, { method: "public.taskfold_edit_team_task" })).code, "PT410");
  // Suspend a real legacy command after root mutation, before receipt insertion.
  const paused = await command({ id: tt, action: "reopen" }), pausedBody = await legacy(paused);
  const pauseKey = 774291;
  await pg.raw(`create function taskfold_private.completion_fixture_pause() returns trigger language plpgsql set search_path='' as $$begin if new.request_id=${lit(paused.request_id)}::uuid then perform pg_advisory_xact_lock(${pauseKey});end if;return new;end$$;create trigger aa_completion_fixture_pause before insert on taskfold_private.team_task_edits for each row execute function taskfold_private.completion_fixture_pause()`);
  const pause = await pg.hold(`select pg_advisory_xact_lock(${pauseKey});`);
  let late;
  try {
    late = run(pausedBody, { method: "public.taskfold_edit_team_task", app: "ordinary-team-before-receipt" });
    const wait = await pg.waitForLock("ordinary-team-before-receipt", pause.pid);
    check("legacy command reaches actual final receipt pause", wait.blockers.includes(pause.pid), true);
    check("closure succeeds while old writer holds mutated root", (await run(paused, { close: true })).value?.outcome, "closed");
    await pause.release("commit");
    check("paused old writer rolls back after decision commits", (await late).code, "PT410");
    check("paused old writer preserves exact root and history", [await row(tt), await history(tt)], [teamBefore, teamHistory]);
  } finally { await pause.release("rollback"); if (late) await late; }
  await pg.raw("drop trigger aa_completion_fixture_pause on taskfold_private.team_task_edits;drop function taskfold_private.completion_fixture_pause()");
  report.stage = "shared team batch receipt fence";
  const closedBatch = await command({ id: tt, action: "reopen" }), batchRow = await row(tt), batchHistory = await history(tt);
  const batch = { team_id: team, request_id: closedBatch.request_id, items: [{ team_id: team, project_id: project, task_id: tt,
    request_id: randomUUID(), task_generation: batchRow.task_generation, record: batchRow, task_type_lifecycle_protocol: 1 }] };
  check("completion closure can reserve unused batch nonce", (await run(closedBatch, { close: true })).value?.outcome, "closed");
  check("ordinary batch refuses closed completion nonce", (await run(batch, { method: "public.taskfold_team_task_batch", operation: "delete" })).code, "PT410");
  check("refused batch preserves exact task and history", [await row(tt), await history(tt)], [batchRow, batchHistory]);
  batch.request_id = randomUUID(); batch.items[0].request_id = randomUUID();
  check("fresh ordinary team batch still works", (await run(batch, { method: "public.taskfold_team_task_batch", operation: "delete" })).code, null);
  check("committed batch nonce cannot become child closure", (await run({ ...closedBatch, request_id: batch.request_id }, { close: true })).code, "PT409");
  check("team completion proof survives team task deletion", (await run(teamDone, { close: true, who: "editor" })).value?.outcome, "applied");
  report.stage = "task-free recovery and quotas";
  const deleted = await command(); await pg.raw(`delete from public.tasks where id=${lit(task)}`);
  check("unapplied request can close after root deletion", (await run(deleted, { close: true })).value?.outcome, "closed");
  check("applied receipt recovers after root deletion", (await run(fresh, { close: true })).value?.receipt?.revision, applied.value?.revision);
  check("closed proof survives root deletion", (await run(c, { close: true })).value, first.value);
  await pg.raw(`insert into taskfold_private.child_task_completion_closures(actor_id,request_id,fingerprint) select ${lit(owner.id)},gen_random_uuid(),repeat('0',64) from generate_series(1,2000)`);
  check("known closure bypasses new quota", (await run(c, { close: true })).value?.outcome, "closed");
  check("known applied receipt bypasses new quota", (await run(fresh, { close: true })).value?.outcome, "applied");
  check("new closure budget safely refuses", (await run({ ...deleted, request_id: randomUUID() }, { close: true })).code, "PT429");
  for (const role of ["anon", "authenticated", "service_role"]) check(role + " direct closure access denied", await pg.scalar(`select to_jsonb(has_table_privilege(${lit(role)},'taskfold_private.child_task_completion_closures','select,insert,update,delete'))`), false);
  check("closure RLS enabled", await pg.scalar("select to_jsonb(relrowsecurity) from pg_class where oid='taskfold_private.child_task_completion_closures'::regclass"), true);
  check("public close is invoker", await pg.scalar("select to_jsonb(not prosecdef) from pg_proc where oid='public.taskfold_close_child_completion(jsonb)'::regprocedure"), true);
  check("anonymous close execution denied", await pg.scalar("select to_jsonb(has_function_privilege('anon','public.taskfold_close_child_completion(jsonb)','execute'))"), false);
  check("private closer fixed search path", await pg.scalar("select to_jsonb('search_path=\"\"'=any(proconfig)) from pg_proc where oid='taskfold_private.close_child_completion(jsonb)'::regprocedure"), true);
  report.finalAdvisors = await pg.advisors();
  const oldFindings = new Set(report.baselineAdvisors.result.map(x => x.cache_key));
  check("no added advisor findings", report.finalAdvisors.result.filter(x => !oldFindings.has(x.cache_key)), []);
  report.passed = true; console.log("PASS " + Object.keys(report.checks).length + " completion resolution database checks");
} catch (error) { report.passed = false; report.error = { name: error.name, code: error.code ?? null, message: error.message }; process.exitCode = 1; console.error("FAIL " + report.stage + ": " + error.message + " " + (error.code ?? "")); }
finally { if (pg) report.containerRemoved = await pg.close(); await writeFile(process.argv[2] ?? "/tmp/taskfold-completion-resolution-database.json", JSON.stringify(report, null, 2) + "\n"); }
