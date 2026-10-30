// Actual bridge transactions in an owned PostgreSQL fixture; no hosted writes.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadWorkflowRunSchema } from "./team-workflow-run-schema.mjs";
import { loadChildTaskRecordsSchema } from "./child-task-records-schema.mjs";

const sql = await readFile(process.env.TASKFOLD_STRUCTURE_SQL ?? new URL("../../supabase/migrations/20261030002245_child_structure_revision_and_assignment_bridge.sql", import.meta.url), "utf8");
const report = { checks: {}, migrationSHA256: createHash("sha256").update(sql).digest("hex"), deployed: false, structuralCommands: false };
const check = (name, actual, expected) => { assert.deepEqual(actual, expected, name); report.checks[name] = true; };
const json = value => lit(JSON.stringify(value)) + "::jsonb";
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadWorkflowRunSchema(pg.raw, { taskTypes: true });
  await loadChildTaskRecordsSchema(pg.raw);
  for (const file of ["20261029001127_child_task_record_reads.sql", "20261029005723_child_task_field_edits.sql", "20261029194600_child_task_field_resolution.sql", "20261029211038_child_task_completion_commands.sql", "20261029215232_child_task_completion_resolution.sql"]) {
    await pg.raw(await readFile(new URL("../../supabase/migrations/" + file, import.meta.url), "utf8"));
  }
  const owner = randomUUID(), session = randomUUID(), task = randomUUID();
  const original = [{ id: "a", title: "Synthetic parent", future: { preserve: [null, false] }, subtasks: [{ id: "nested", title: "Nested", subtasks: null }] }, { id: "b", title: "Sibling" }];
  await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(owner)},'structure@example.invalid',now());insert into auth.sessions(id,user_id) values(${lit(session)},${lit(owner)});insert into public.tasks(id,user_id,title,subtasks) values(${lit(task)},${lit(owner)},'Synthetic structure',${json(original)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)};`);
  const projection = () => pg.scalar(`select to_jsonb(p) from taskfold_private.child_task_projections p where task_id=${lit(task)}`);
  const records = () => pg.scalar(`select coalesce(jsonb_agg(to_jsonb(r) order by node_key),'[]') from taskfold_private.child_task_records r where task_id=${lit(task)}`);
  const row = () => pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(task)}`);
  const save = async tree => {
    const outcome = await pg.scalar(`create temp table structure_result(code text,reason text,context text);do $save$declare context text;begin begin update public.tasks set subtasks=${tree === null ? "null" : json(tree)} where id=${lit(task)};insert into structure_result values(null,null,null);exception when others then get stacked diagnostics context=PG_EXCEPTION_CONTEXT;insert into structure_result values(sqlstate,left(sqlerrm,200),context);end;end$save$;select to_jsonb(r) from structure_result r;`);
    if (outcome.code) { const error = new Error(outcome.reason); error.code = outcome.code; error.context = outcome.context; throw error; }
  };
  const edit = async change => { const tree = (await row()).subtasks; change(tree); await save(tree); };
  await edit(tree => { tree[0].title = "Pre-migration field edit"; });
  const sourceBeforeNull = (await row()).subtasks;
  let legacyNullCode;
  try { await edit(tree => { tree[0].subtasks = null; }); } catch (error) { legacyNullCode = error.code; }
  check("pre-migration assignment guard reproduces null-container failure", legacyNullCode, "22023");
  check("pre-migration failed write preserves original tree", (await row()).subtasks, sourceBeforeNull);
  report.baselineAdvisors = await pg.advisors();
  await pg.raw(sql);
  check("existing projection starts structural fence at one", (await projection()).structure_revision, 1);
  check("preexisting general revision is retained", (await projection()).revision, 2);
  const before = await records();
  await edit(tree => { tree[0].title = "Disjoint title"; tree[0].description = "Retained notes"; tree[0].future.more = true; });
  check("own fields do not advance structure", (await projection()).structure_revision, 1);
  check("own fields still advance general projection", (await projection()).revision, 3);
  check("unknown fields survive", (await row()).subtasks[0].future, { preserve: [null, false], more: true });
  await edit(tree => { tree[0].completed = false; tree[0].completed_at = null; tree[0].taskfold_completion_v1 = { epoch: randomUUID(), version: 0 }; });
  check("completion cohort is independent of topology", (await projection()).structure_revision, 1);
  const baselineTree = (await row()).subtasks;
  await edit(tree => { tree.reverse(); });
  check("sibling reorder advances structure", (await projection()).structure_revision, 2);
  await save(baselineTree);
  check("restoring sibling order retains ABA evidence", (await projection()).structure_revision, 3);
  check("reorder keeps all node incarnations", (await records()).map(r => r.incarnation), before.map(r => r.incarnation));
  await edit(tree => { tree[1].subtasks = [tree[0].subtasks.pop()]; });
  check("reparent advances structure once per transaction", (await projection()).structure_revision, 4);
  check("reparent preserves child incarnation", (await records()).find(r => r.node_key === "nested").incarnation, before.find(r => r.node_key === "nested").incarnation);
  check("reparent updates raw path", (await records()).find(r => r.node_key === "nested").identity_path, ["b", "nested"]);
  await edit(tree => { tree[0].subtasks = null; });
  check("empty array to null advances structure", (await projection()).structure_revision, 5);
  await edit(tree => { delete tree[0].subtasks; });
  check("null to absent advances structure", (await projection()).structure_revision, 6);
  const withNested = (await row()).subtasks, nestedBefore = (await records()).find(r => r.node_key === "nested");
  await edit(tree => { tree[1].subtasks = []; });
  check("deletion advances structure", (await projection()).structure_revision, 7);
  await save(withNested);
  check("restore advances structure", (await projection()).structure_revision, 8);
  check("restored node gets fresh incarnation", (await records()).find(r => r.node_key === "nested").incarnation === nestedBefore.incarnation, false);
  const stable = await projection(), stableRoot = await row();
  const holder = await pg.hold(`update public.tasks set subtasks=${json([...withNested].reverse())} where id=${lit(task)};`);
  try {
    check("uncommitted topology invisible to another connection", await projection(), stable);
  } finally { await holder.release("rollback"); }
  check("rollback restores full projection and counter", await projection(), stable);
  check("rollback restores source", (await row()).subtasks, stableRoot.subtasks);
  await pg.raw(`create function taskfold_private.fixture_structure_failure() returns trigger language plpgsql set search_path='' as $$begin raise exception using errcode='23514',message='Injected derived-row failure';end$$;create trigger fixture_structure_failure before update on taskfold_private.child_task_records for each row execute function taskfold_private.fixture_structure_failure();`);
  let injectedCode;
  try { await save([...withNested].reverse()); } catch (error) { injectedCode = error.code; }
  check("injected derived-row failure reached", injectedCode, "23514");
  check("derived-row failure rolls back structural fence", await projection(), stable);
  check("derived-row failure rolls back root", (await row()).subtasks, stableRoot.subtasks);
  await pg.raw(`drop trigger fixture_structure_failure on taskfold_private.child_task_records;drop function taskfold_private.fixture_structure_failure();`);
  const first = await pg.hold(`update public.tasks set subtasks=${json([...withNested].reverse())} where id=${lit(task)};`);
  let waiting;
  try {
    waiting = pg.scalar(`begin;set application_name='child-structure-wait';with changed as (update public.tasks set subtasks=${json(withNested)} where id=${lit(task)} returning id) select to_jsonb(count(*)) from changed;commit;`);
    await pg.waitForLock("child-structure-wait", first.pid);
    await first.release("commit");
    check("concurrent structure edit applies after row lock", await waiting, 1);
  } finally { await first.release("rollback"); if (waiting) await waiting; }
  check("serialized reorder and restoration both advance fence", (await projection()).structure_revision, stable.structure_revision + 2);
  check("serialized final source exact", (await row()).subtasks, withNested);
  const validRevision = (await projection()).structure_revision;
  await save([{ id: "duplicate" }, { id: "duplicate" }]);
  check("ambiguous hierarchy enters review", (await projection()).state, "review");
  check("invalid entry advances structure", (await projection()).structure_revision, validRevision + 1);
  check("invalid entry removes addressable records", await records(), []);
  await save(withNested);
  check("recovery advances structure again", (await projection()).structure_revision, validRevision + 2);
  check("review recovery gives fresh incarnations", (await records()).some(r => before.some(p => r.incarnation === p.incarnation)), false);
  await save(null);
  const nullRevision = (await projection()).structure_revision;
  await save([]);
  check("null root versus empty array fenced", (await projection()).structure_revision, nullRevision + 1);
  await save([{ id: "e\u0301", title: "Canonical identity" }]);
  const unicodeRevision = (await projection()).structure_revision, unicodeNode = (await records())[0];
  await save([{ id: "é", title: "Canonical identity" }]);
  check("raw path change fenced even with same normalized key", (await projection()).structure_revision, unicodeRevision + 1);
  check("canonical key retains incarnation", (await records())[0].incarnation, unicodeNode.incarnation);
  const same = await projection();
  await pg.raw(`select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)}`);
  check("repeated adoption does not advance either revision", await projection(), same);
  await pg.raw(`update taskfold_private.child_task_projections set structure_revision=1 where task_id=${lit(task)}`);
  check("ordinary projection update cannot reset structural fence", (await projection()).structure_revision, same.structure_revision);
  await pg.raw(`begin;alter table public.tasks disable trigger taskfold_guard_generation;update public.tasks set task_generation=null where id=${lit(task)};alter table public.tasks enable trigger taskfold_guard_generation;commit;`);
  check("generation transition advances structural fence", (await projection()).structure_revision, same.structure_revision + 1);
  check("generation transition refreshes incarnation", (await records())[0].incarnation === unicodeNode.incarnation, false);
  await pg.raw(`begin;alter table public.tasks disable trigger taskfold_guard_generation;update public.tasks set task_generation=${lit(randomUUID())} where id=${lit(task)};alter table public.tasks enable trigger taskfold_guard_generation;commit;`);
  check("generation restoration also advances structural fence", (await projection()).structure_revision, same.structure_revision + 2);
  await pg.raw(`update taskfold_private.child_task_record_config set reads_enabled=true where singleton`);
  const root = await row();
  const response = await pg.scalar(`begin;set local role authenticated;set local request.jwt.claim.sub=${lit(owner)};set local request.jwt.claims=${lit(JSON.stringify({ sub: owner, session_id: session }))};select public.taskfold_read_child_tasks(${lit(task)},${lit(root.task_generation)});commit;`);
  check("v1 envelope stays exact", Object.keys(response).sort(), ["protocol", "account", "task_id", "project_id", "task_generation", "projection_revision", "root_kind", "records"].sort());
  check("v1 record stays exact", Object.keys(response.records[0]).sort(), ["node_key", "incarnation", "revision", "parent_key", "sibling_order", "identity_path", "fields", "children_kind"].sort());
  const outsider = randomUUID();
  await pg.raw(`insert into auth.users(id,email) values(${lit(outsider)},'outside-structure@example.invalid')`);
  const deep = recipient => [{ id: "one", title: "One", subtasks: [{ id: "two", title: "Two", subtasks: [{ id: "three", title: "Three", subtasks: [{ id: "four", title: "Four", assigned_to: recipient, subtasks: null }] }] }] }];
  const beforeDenied = await projection(), rootBeforeDenied = await row();
  let deniedCode;
  try { await save(deep(outsider)); } catch (error) { deniedCode = error.code; }
  check("assignment outside personal workspace refused at fourth level", deniedCode, "P0001");
  check("denied deep assignment preserves projection", await projection(), beforeDenied);
  check("denied deep assignment preserves root", (await row()).subtasks, rootBeforeDenied.subtasks);
  await save(deep(owner));
  check("valid deep assignment survives with null container", (await row()).subtasks, deep(owner));
  check("valid deep structure advances fence exactly once", (await projection()).structure_revision, beforeDenied.structure_revision + 1);
  const beforeCreator = await row();
  let creatorCode;
  try { await pg.raw(`update public.tasks set user_id=${lit(outsider)} where id=${lit(task)}`); } catch (error) { creatorCode = error.code; }
  check("creator change guard remains enforced", creatorCode, "P0001");
  check("creator refusal preserves owner", (await row()).user_id, beforeCreator.user_id);
  for (const role of ["anon", "authenticated", "service_role"]) {
    check(role + " cannot call topology", await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},'taskfold_private.child_task_topology(jsonb)','execute'))`), false);
    check(role + " cannot call trigger helper", await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},'taskfold_private.advance_child_task_structure()','execute'))`), false);
    check(role + " cannot update projection", await pg.scalar(`select to_jsonb(has_table_privilege(${lit(role)},'taskfold_private.child_task_projections','update'))`), false);
  }
  check("projection remains protected by RLS", await pg.scalar(`select to_jsonb(relrowsecurity) from pg_class where oid='taskfold_private.child_task_projections'::regclass`), true);
  report.advisors = await pg.advisors();
  const baselineKeys = new Set(report.baselineAdvisors.result.map(x => x.cache_key));
  check("no added advisor findings", report.advisors.result.filter(x => !baselineKeys.has(x.cache_key)), []);
  report.serverVersion = pg.serverVersion;
} catch (error) { report.error = { message: error.message, code: error.code, context: error.context }; throw error; }
finally {
  if (pg) report.containerRemoved = await pg.close();
  report.checkCount = Object.keys(report.checks).length;
  if (process.argv[2]) await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
}
console.log(JSON.stringify({ checks: report.checkCount, containerRemoved: report.containerRemoved }));
