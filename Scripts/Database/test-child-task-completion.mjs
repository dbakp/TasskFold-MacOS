import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadWorkflowRunSchema } from "./team-workflow-run-schema.mjs";
import { loadChildTaskRecordsSchema } from "./child-task-records-schema.mjs";

const candidate = await readFile(process.env.TASKFOLD_COMPLETION_SQL ?? new URL("../../supabase/migrations/20261029211038_child_task_completion_commands.sql", import.meta.url), "utf8");
const report = { checks: {}, candidateSHA256: createHash("sha256").update(candidate).digest("hex"), deployed: false };
const json = value => lit(JSON.stringify(value)) + "::jsonb";
const cohort = fields => Object.fromEntries(Object.entries(fields).filter(([k]) => ["completed", "completed_at", "is_heading", "taskfold_completion_v1"].includes(k)));
const check = (name, actual, expected) => { assert.deepEqual(actual, expected, name); report.checks[name] = true; };
let pg;
try {
  report.stage = "owned database with actual node history and custody";
  pg = await createPostgresFixture({ advisors: true });
  process.env.TASKFOLD_TEST_NODE_ADOPTION = "0";
  process.env.TASKFOLD_TEST_HISTORY_CUSTODY = "0";
  await loadWorkflowRunSchema(pg.raw, { taskTypes: true });
  for (const file of ["20261026095807_task_node_activity_history.sql", "20261026104450_task_activity_root_context.sql", "20261026113556_task_node_activity_custody.sql", "20261026121332_task_node_project_adoption_review.sql", "20261026122805_reviewed_history_custody.sql"]) {
    await pg.raw(await readFile(new URL("../../supabase/migrations/" + file, import.meta.url), "utf8"));
  }
  await loadChildTaskRecordsSchema(pg.raw);
  for (const file of ["20261029001127_child_task_record_reads.sql", "20261029005723_child_task_field_edits.sql", "20261029194600_child_task_field_resolution.sql"]) {
    await pg.raw(await readFile(new URL("../../supabase/migrations/" + file, import.meta.url), "utf8"));
  }
  report.baselineAdvisors = await pg.advisors();
  report.stage = "direct candidate SQL";
  const schemaResult = await pg.scalar(`create temp table schema_result(code text,reason text,context text);do $load$declare context text;begin begin execute ${lit(candidate)};insert into schema_result values(null,null,null);exception when others then get stacked diagnostics context=PG_EXCEPTION_CONTEXT;insert into schema_result values(sqlstate,sqlerrm,context);end;end$load$;select to_jsonb(r) from schema_result r;drop table schema_result;`);
  if (schemaResult.code) { report.schemaDiagnostic = schemaResult; throw new Error(schemaResult.reason); }
  if (process.argv.includes("--with-completion-resolution")) {
    const resolution = await readFile(new URL("../../supabase/migrations/20261029215232_child_task_completion_resolution.sql", import.meta.url), "utf8");
    await pg.raw(resolution);
    report.completionResolutionSHA256 = createHash("sha256").update(resolution).digest("hex");
  }
  if (process.env.TASKFOLD_STRUCTURE_SQL) {
    const structure = await readFile(process.env.TASKFOLD_STRUCTURE_SQL, "utf8");
    await pg.raw(structure);
    report.structureMigrationSHA256 = createHash("sha256").update(structure).digest("hex");
  }
  if (process.env.TASKFOLD_STRUCTURE_COMMAND_SQL) {
    if (!process.env.TASKFOLD_STRUCTURE_SQL) throw new Error("Structure-command regression requires the structure revision migration");
    const structureCommands = await readFile(process.env.TASKFOLD_STRUCTURE_COMMAND_SQL, "utf8");
    await pg.raw(structureCommands);
    report.structureCommandsMigrationSHA256 = createHash("sha256").update(structureCommands).digest("hex");
  }
  if (process.env.TASKFOLD_FIELD_NATIVE_SQL) {
    const nativeField = await readFile(process.env.TASKFOLD_FIELD_NATIVE_SQL, "utf8");
    await pg.raw(nativeField);
    report.nativeFieldMigrationSHA256 = createHash("sha256").update(nativeField).digest("hex");
  }
  const people = Object.fromEntries(["owner", "writer", "viewer", "outside"].map(k => [k, { id: randomUUID(), session: randomUUID() }]));
  for (const u of Object.values(people)) await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit(u.id + "@example.invalid")},now());insert into public.profiles(user_id) values(${lit(u.id)});insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});`);
  const owner = people.owner, task = randomUUID(), project = randomUUID();
  const source = [{ id: "child", title: "Synthetic child", completed: false, completed_at: null,
    taskfold_completion_v1: { epoch: randomUUID(), version: 0 }, future: { preserve: [null, false] },
    subtasks: [{ id: "descendant", title: "Untouched descendant", subtasks: null }] },
    { id: "sibling", title: "Untouched sparse sibling", future: { opaque: true } }];
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(project)},${lit(owner.id)},'Synthetic completion project');insert into public.tasks(id,user_id,project_id,title,subtasks) values(${lit(task)},${lit(owner.id)},${lit(project)},'Synthetic completion root',${json(source)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)}`);
  const row = (id = task) => pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(id)}`);
  const node = (id = task, key = "child") => pg.scalar(`select to_jsonb(n) from taskfold_private.child_task_records n where task_id=${lit(id)} and node_key=${lit(key)}`);
  const history = (id = task) => pg.scalar(`select coalesce(jsonb_agg(to_jsonb(a) order by sequence),'[]') from public.task_node_activity a where task_id=${lit(id)}`);
  const claims = (who = "owner", session = people[who].session) => `set local role authenticated;set local request.jwt.claim.sub=${lit(people[who].id)};set local request.jwt.claims=${lit(JSON.stringify({ sub: people[who].id, session_id: session }))};`;
  const run = (body, { who = "owner", session = people[who].session, fn = "public.taskfold_complete_child_task", app = "child-completion" } = {}) => pg.scalar(`begin;set application_name=${lit(app)};create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated;${claims(who, session)}do $op$begin begin insert into result values(${fn}(${json(body)}),null,null);exception when others then insert into result values(null,sqlstate,left(sqlerrm,180));end;end$op$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`);
  const command = async (action = "complete", { id = task, key = "child", who = "owner", undo = null } = {}) => {
    const r = await row(id), n = await node(id, key);
    return { protocol: 1, account: people[who].id, request_id: randomUUID(), task_id: id, task_generation: r.task_generation,
      project_id: r.project_id, node_key: key, incarnation: n.incarnation, revision: n.revision, action,
      ...(action === "undo" ? { undo_of: undo } : { baseline: cohort(n.fields) }) };
  };
  const saveTree = async (transform, id = task) => { const r = await row(id); transform(r.subtasks); await pg.raw(`update public.tasks set subtasks=${json(r.subtasks)} where id=${lit(id)}`); };
  const first = await command(), before = await row(), beforeHistory = await history();
  check("completion disabled by default", (await run(first)).code, "PT503");
  await pg.raw("update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true");
  check("completion has its own disabled gate", (await run(first)).code, "PT503");
  await pg.raw("update taskfold_private.child_task_record_config set completions_enabled=true");
  report.stage = "personal completion and actual history";
  const complete = await run(first);
  report.fixtureCommand = first;
  report.firstCompletion = complete;
  check("personal completion applies", complete.code, null);
  const completed = await row(), after = await history();
  check("only chosen child completed", [completed.completed, completed.completion_version, completed.subtasks[0].completed, completed.subtasks[1]], [before.completed, before.completion_version, true, before.subtasks[1]]);
  check("raw descendant null container preserved", completed.subtasks[0].subtasks, before.subtasks[0].subtasks);
  check("opaque fields preserved", completed.subtasks[0].future, before.subtasks[0].future);
  check("completion token advances", completed.subtasks[0].taskfold_completion_v1, { ...source[0].taskfold_completion_v1, version: 1 });
  check("actual history records one completion", after.slice(beforeHistory.length).map(x => [x.node_key, x.kinds, x.actor_id, x.completion_version]), [["child", ["completed"], owner.id, 1]]);
  check("actual history uses saved completion time", new Date(after.at(-1).effective_at).toISOString(), new Date(completed.subtasks[0].completed_at).toISOString());
  const replay = await run(first);
  check("exact retry returns original proof", { ...replay.value, replayed: false }, complete.value);
  check("exact retry emits no history", await history(), after);
  check("changed nonce body refused", (await run({ ...first, revision: first.revision + 1 })).code, "PT409");
  report.stage = "disjoint edit and certified Undo";
  await saveTree(tree => { tree[0].title = "Keep unrelated edit after completion"; });
  const undo = await command("undo", { undo: first.request_id }), undone = await run(undo);
  report.fixtureUndoCommand = undo; report.firstUndo = undone;
  check("certified Undo applies after disjoint edit", undone.code, null);
  const restored = await row();
  check("Undo keeps unrelated title", restored.subtasks[0].title, "Keep unrelated edit after completion");
  check("Undo restores original flags and time", [restored.subtasks[0].completed, restored.subtasks[0].completed_at], [false, null]);
  check("Undo advances same epoch", restored.subtasks[0].taskfold_completion_v1, { ...source[0].taskfold_completion_v1, version: 2 });
  check("Undo history is real reopen at new version", (await history()).at(-1).kinds, ["reopened"]);
  check("Undo history revision matches token", (await history()).at(-1).completion_version, 2);
  const undoHistory = await history();
  check("Undo exact retry returns original proof", (await run(undo)).value.revision, undone.value.revision);
  check("Undo retry emits no history", await history(), undoHistory);
  check("second identity cannot Undo original twice", (await run(await command("undo", { undo: first.request_id }))).code, "PT409");
  check("cannot Undo another Undo", (await run(await command("undo", { undo: undo.request_id }))).code, "PT409");
  report.stage = "historical completion time and ABA";
  const historic = "2026-10-01T09:30:00Z";
  await saveTree(tree => { tree[0].completed = true; tree[0].completed_at = historic; tree[0].taskfold_completion_v1.version++; });
  const reopen = await command("reopen"); check("reopen applies", (await run(reopen)).code, null);
  check("Undo reopen restores exact historical time", (await run(await command("undo", { undo: reopen.request_id }))).value.after.completed_at, historic);
  const cycleOriginal = await command("reopen"); check("cycle setup reopen applies", (await run(cycleOriginal)).code, null);
  const staleUndo = await command("undo", { undo: cycleOriginal.request_id }), cycle1 = await command();
  check("cycle complete applies", (await run(cycle1)).code, null);
  check("cycle reopen applies", (await run(await command("reopen"))).code, null);
  check("ABA cycle prevents old Undo", (await run(staleUndo)).code, "PT409");
  const disjoint = await command(); await saveTree(tree => { tree[0].description = "New notes while pending"; });
  check("pending completion allows disjoint notes", (await run(disjoint)).code, null);
  const stale = await command("reopen");
  await saveTree(tree => { tree[0].completed = false; tree[0].completed_at = null; tree[0].taskfold_completion_v1.version++; });
  await saveTree(tree => { tree[0].completed = true; tree[0].completed_at = historic; tree[0].taskfold_completion_v1.version++; });
  check("pending completion catches cycle", (await run(stale)).code, "PT409");
  report.stage = "identity permissions and rollback";
  for (const [name, patch] of [["wrong generation", { task_generation: randomUUID() }], ["wrong project", { project_id: randomUUID() }], ["replaced incarnation", { incarnation: randomUUID() }]]) check(name, (await run({ ...await command("reopen"), ...patch })).code, "PT409");
  check("outsider denied", (await run(await command("reopen", { who: "outside" }), { who: "outside" })).code, "42501");
  check("wrong intended account denied", (await run(await command("reopen"), { who: "outside" })).code, "42501");
  check("missing session denied", (await run(await command("reopen"), { session: null })).code, "28000");
  for (const [name, patch] of [["unknown envelope", { unknown: true }], ["tree smuggling", { subtasks: [] }], ["bad state", { baseline: { completed: null } }], ["no-op action", { action: "complete" }], ["timestamp smuggling", { completed_at: historic }], ["missing Undo receipt", { action: "undo", undo_of: randomUUID(), baseline: undefined }]]) {
    const body = { ...await command("reopen"), ...patch };
    check(name, (await run(body)).code, name === "missing Undo receipt" ? "PT409" : "22023");
  }
  const snap = await row(), ledger = await history();
  const forged = { ...await command("reopen"), baseline: { completed: true, completed_at: "2026-10-02T10:00:00Z" } };
  check("forged baseline denied", (await run(forged)).code, "PT409");
  check("refusal leaves exact task unchanged", await row(), snap);check("refusal adds no history", await history(), ledger);
  const field = { ...await command("reopen"), changes: { title: "Never allowed via reused nonce" } }; delete field.action; delete field.baseline;
  field.request_id = first.request_id;
  check("completion nonce cannot become field edit", (await run(field, { fn: "public.taskfold_edit_child_task" })).code, "PT409");
  check("completion nonce cannot become field closure", (await run(field, { fn: "public.taskfold_close_child_task_edit" })).code, "PT409");
  field.request_id = randomUUID(); check("field closure reserves new identity", (await run(field, { fn: "public.taskfold_close_child_task_edit" })).code, null);
  check("closed field nonce cannot become completion", (await run({ ...await command("reopen"), request_id: field.request_id })).code, "PT409");
  report.stage = "legacy raw preservation";
  const sparse = await command("complete", { key: "sibling" });
  await saveTree(tree => { tree[1].title = "Legacy changed before send"; });
  check("legacy token absence requires exact revision", (await run(sparse)).code, "PT409");
  const sparseFresh = await command("complete", { key: "sibling" });check("fresh sparse completion bootstraps metadata", (await run(sparseFresh)).code, null);
  check("sparse Undo applies", (await run(await command("undo", { key: "sibling", undo: sparseFresh.request_id }))).code, null);
  const sparseAfter = (await row()).subtasks[1];
  check("sparse Undo restores absent flags and containers", [Object.hasOwn(sparseAfter, "completed"), Object.hasOwn(sparseAfter, "completed_at"), Object.hasOwn(sparseAfter, "subtasks")], [false, false, false]);
  check("sparse Undo retains monotone token", sparseAfter.taskfold_completion_v1.version, 2);
  report.stage = "team role and exact raw fields";
  const team = randomUUID(), tp = randomUUID(), tt = randomUUID();
  await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'Synthetic completion team');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin'),(${lit(team)},${lit(people.writer.id)},'member'),(${lit(team)},${lit(people.viewer.id)},'guest');insert into public.projects(id,user_id,name) values(${lit(tp)},${lit(owner.id)},'Synthetic team project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(tp)},${lit(team)},'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(tp)},${lit(team)},${lit(people.writer.id)},'editor'),(${lit(tp)},${lit(team)},${lit(people.viewer.id)},'viewer');insert into public.tasks(id,user_id,project_id,title,subtasks) values(${lit(tt)},${lit(owner.id)},${lit(tp)},'Synthetic team root',${json(source)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(tt)}`);
  const teamBody = await command("complete", { id: tt, who: "writer" });
  check("team gate still required", (await run(teamBody, { who: "writer" })).code, "PT503");
  await pg.raw("update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true");
  check("viewer completion denied", (await run(await command("complete", { id: tt, who: "viewer" }), { who: "viewer" })).code, "42501");
  const teamResult = await run(teamBody, { who: "writer" });check("team editor completion applies", teamResult.code, null);
  check("team sparse sibling unchanged", (await row(tt)).subtasks[1], source[1]);
  check("team null descendant unchanged", (await row(tt)).subtasks[0].subtasks, source[0].subtasks);
  check("team history actual editor and version", [(await history(tt)).at(-1).actor_id, (await history(tt)).at(-1).completion_version], [people.writer.id, 1]);
  const teamUndo = await command("undo", { id: tt, who: "writer", undo: teamBody.request_id });
  check("another actor cannot use completion receipt", (await run({ ...teamUndo, account: owner.id, request_id: randomUUID() })).code, "PT409");
  check("team Undo applies", (await run(teamUndo, { who: "writer" })).code, null);
  check("team nonce reserved in shared ledger", await pg.scalar(`select to_jsonb(operation) from taskfold_private.team_task_edits where team_id=${lit(team)} and request_id=${lit(teamBody.request_id)}`), "child_completion");
  const legacyTeam = { team_id: team, project_id: tp, task_id: tt, task_generation: (await row(tt)).task_generation,
    request_id: teamBody.request_id, base: await row(tt), changes: { title: "Synthetic legacy team edit" } };
  check("completion nonce refused by ordinary team edit", (await run(legacyTeam, { who: "writer", fn: "public.taskfold_edit_team_task" })).code, "PT409");
  legacyTeam.request_id = randomUUID();
  check("ordinary team command still works", (await run(legacyTeam, { who: "writer", fn: "public.taskfold_edit_team_task" })).code, null);
  check("ordinary team nonce refused by completion", (await run({ ...await command("complete", { id: tt, who: "writer" }), request_id: legacyTeam.request_id }, { who: "writer" })).code, "PT409");
  await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(tp)} and user_id=${lit(people.writer.id)}`);
  check("revoked editor replay denied", (await run(teamBody, { who: "writer" })).code, "42501");
  report.stage = "real concurrent actor lock and final permissions";
  const race = await command("reopen");
  const hold = await pg.hold(`${claims()}select public.taskfold_complete_child_task(${json(race)});`);
  let pending;
  try {
    pending = run(race, { app: "child-completion-retry-wait" });
    const wait = await pg.waitForLock("child-completion-retry-wait", hold.pid);
    check("real retry waits for owned actor lock", wait.blockers.includes(hold.pid), true);
    await hold.release("commit");
    check("waiting retry returns committed receipt", (await pending).value.replayed, true);
  } finally { await hold.release("rollback"); if (pending) await pending; }
  report.stage = "expiry during actual root wait";
  const expiring = await command();
  await pg.raw(`update auth.sessions set not_after=clock_timestamp()+interval '2 seconds' where id=${lit(owner.session)}`);
  const rootHold = await pg.hold(`select 1 from public.tasks where id=${lit(task)} for update;`);
  let expiryPending;
  try {
    expiryPending = run(expiring, { app: "child-completion-expiry-wait" });
    const wait = await pg.waitForLock("child-completion-expiry-wait", rootHold.pid);
    check("expiry test reaches actual root lock", wait.blockers.includes(rootHold.pid), true);
    await pg.raw("select pg_sleep(2.1)");
    await rootHold.release("commit");
    check("expired session after root wait denied", (await expiryPending).code, "28000");
  } finally { await rootHold.release("rollback"); if (expiryPending) await expiryPending; }
  await pg.raw(`update auth.sessions set not_after=null where id=${lit(owner.session)}`);
  report.stage = "guards and post-update rollback";
  const rollbackBody = await command(), rollbackRow = await row(), rollbackHistory = await history();
  await pg.raw(`create function public.completion_fixture_tamper() returns trigger language plpgsql set search_path='' as $$begin if new.id=${lit(task)}::uuid then new.subtasks=jsonb_set(new.subtasks,'{0,title}','"Synthetic injected title"');end if;return new;end$$;create trigger zz_completion_fixture_tamper before update on public.tasks for each row execute function public.completion_fixture_tamper();`);
  check("post-update mismatch refuses completion", (await run(rollbackBody)).code, "PT409");
  check("post-update refusal restores exact row", await row(), rollbackRow);
  check("post-update refusal rolls back actual history", await history(), rollbackHistory);
  check("post-update refusal records no receipt", await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.child_task_completion_receipts where actor_id=${lit(owner.id)} and request_id=${lit(rollbackBody.request_id)}`), 0);
  await pg.raw("drop trigger zz_completion_fixture_tamper on public.tasks;drop function public.completion_fixture_tamper()");
  await pg.raw(`create policy completion_fixture_deny on public.tasks as restrictive for select to authenticated using(id<>${lit(task)}::uuid)`);
  check("public wrapper honors caller RLS", (await run(rollbackBody)).code, "42501");
  check("wrapper refusal rolls back row and history", [await row(), await history()], [rollbackRow, rollbackHistory]);
  await pg.raw("drop policy completion_fixture_deny on public.tasks");
  await pg.raw(`update public.projects set is_archived=true where id=${lit(project)}`);
  check("archive blocks completion and applied replay", [(await run(rollbackBody)).code, (await run(first)).code], ["PT409", "PT409"]);
  await pg.raw(`update public.projects set is_archived=false where id=${lit(project)}`);
  await pg.raw(`update auth.users set banned_until=clock_timestamp()+interval '1 day' where id=${lit(owner.id)}`);
  check("banned actor cannot replay", (await run(first)).code, "28000");
  await pg.raw(`update auth.users set banned_until=null where id=${lit(owner.id)}`);
  await saveTree(tree => { tree[0].is_heading = false; });
  const savedTree = (await row()).subtasks;
  for (const [name, patch, code] of [["heading", { is_heading: true }, "22023"], ["malformed token", { taskfold_completion_v1: null }, "22023"], ["exhausted revision", { taskfold_completion_v1: { epoch: source[0].taskfold_completion_v1.epoch, version: 9007199254740990 } }, "PT409"]]) {
    await saveTree(tree => { Object.assign(tree[0], patch); });
    const n = await node(), r = await row();
    const body = { ...rollbackBody, request_id: randomUUID(), incarnation: n.incarnation, revision: n.revision, baseline: cohort(n.fields), task_generation: r.task_generation };
    check(name + " refuses completion", (await run(body)).code, code);
    await pg.raw(`update public.tasks set subtasks=${json(savedTree)} where id=${lit(task)}`);
  }
  check("future type baseline refused", (await run({ ...await command(), baseline: { completed: false, is_heading: "future" } })).code, "22023");
  const deleted = await command();
  await saveTree(tree => { tree.shift(); });
  check("deleted child cannot complete", (await run(deleted)).code, "PT409");
  await pg.raw(`update public.tasks set subtasks=${json(savedTree)} where id=${lit(task)}`);
  check("recreated child cannot use old incarnation", (await run(deleted)).code, "PT409");
  check("legacy history revision fallback retained", await pg.scalar("select to_jsonb(taskfold_private.node_activity_revision('{\"completion_version\":7}'::jsonb))"), 7);
  check("history token version takes precedence", await pg.scalar(`select to_jsonb(taskfold_private.node_activity_revision(${json({ completion_version: 7, taskfold_completion_v1: { epoch: source[0].taskfold_completion_v1.epoch, version: 4 } })}))`), 4);
  report.stage = "bounded completion receipt budget";
  await pg.raw(`insert into taskfold_private.child_task_completion_receipts(actor_id,request_id,fingerprint,task_id,generation,project_id,node_key,incarnation,revision,action,before_state,after_state)
    select actor_id,gen_random_uuid(),repeat('0',64),task_id,generation,project_id,node_key,incarnation,revision,action,before_state,after_state
    from taskfold_private.child_task_completion_receipts cross join generate_series(1,2000) where actor_id=${lit(owner.id)} and request_id=${lit(first.request_id)};`);
  check("new request refused by receipt budget", (await run(await command())).code, "PT429");
  check("known replay bypasses new request budget", (await run(first)).value.replayed, true);
  check("scope rows removed", await pg.scalar("select to_jsonb(count(*)) from taskfold_private.team_task_edit_scope"), 0);
  check("receipt table RLS enabled", await pg.scalar("select to_jsonb(relrowsecurity) from pg_class where oid='taskfold_private.child_task_completion_receipts'::regclass"), true);
  for (const role of ["anon", "authenticated", "service_role"]) check(role + " direct receipt access denied", await pg.scalar(`select to_jsonb(has_table_privilege(${lit(role)},'taskfold_private.child_task_completion_receipts','select,insert,update,delete'))`), false);
  check("anonymous RPC denied", await pg.scalar("select to_jsonb(has_function_privilege('anon','public.taskfold_complete_child_task(jsonb)','execute'))"), false);
  check("public RPC invoker", await pg.scalar("select to_jsonb(not prosecdef) from pg_proc where oid='public.taskfold_complete_child_task(jsonb)'::regprocedure"), true);
  check("private function fixed search path", await pg.scalar("select to_jsonb('search_path=\"\"'=any(proconfig)) from pg_proc where oid='taskfold_private.complete_child_task(jsonb)'::regprocedure"), true);
  report.finalAdvisors = await pg.advisors();
  const old = new Set(report.baselineAdvisors.result.map(x => x.cache_key));
  check("no added advisor findings", report.finalAdvisors.result.filter(x => !old.has(x.cache_key)), []);
  report.passed = true;
  console.log("PASS " + Object.keys(report.checks).length + " child completion database checks");
} catch (error) {
  report.passed = false; report.error = { name: error.name, code: error.code ?? null, message: error.message }; process.exitCode = 1;
  console.error("FAIL " + report.stage + ": " + error.message + " " + (error.code ?? ""));
} finally {
  if (pg) report.containerRemoved = await pg.close();
  await writeFile(process.argv[2] ?? "/tmp/taskfold-child-completion-database.json", JSON.stringify(report, null, 2) + "\n");
}
