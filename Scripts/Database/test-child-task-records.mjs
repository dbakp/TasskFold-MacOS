// Real owned PostgreSQL checks; no hosted data or production rollout.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamTaskLifecycle } from "./team-task-schema.mjs";
import { loadTeamChecklistSchema } from "./team-checklist-schema.mjs";
import { childTaskRecordsMigration } from "./child-task-records-schema.mjs";
const sql = await readFile(
  new URL(
    "../../supabase/migrations/" + childTaskRecordsMigration,
    import.meta.url,
  ),
  "utf8",
);
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
const report = {
  checks: {},
  migrationSHA256: createHash("sha256").update(sql).digest("hex"),
  deployed: false,
  clientAdoption: false,
  independentWrites: false,
};
const check = (name, actual, expected) => {
  assert.deepEqual(actual, expected, name);
  report.checks[name] = true;
};
const pg = await createPostgresFixture({ advisors: true });
try {
  await loadTeamTaskLifecycle(pg.raw);
  await loadTeamChecklistSchema(pg.raw);
  report.baselineAdvisors = await pg.advisors();
  await pg.raw(sql);
  const owner = randomUUID(), other = randomUUID(), task = randomUUID();
  await pg.raw(
    `insert into auth.users(id) values(${lit(owner)}),(${
      lit(other)
    });insert into public.tasks(id,user_id,title) values(${lit(task)},${
      lit(owner)
    },'Synthetic child records');`,
  );
  const root = () =>
    pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(task)}`);
  const projection = () =>
    pg.scalar(
      `select to_jsonb(p) from taskfold_private.child_task_projections p where task_id=${
        lit(task)
      }`,
    );
  const records = () =>
    pg.scalar(
      `select coalesce(jsonb_agg(to_jsonb(r) order by node_key),'[]') from taskfold_private.child_task_records r where task_id=${
        lit(task)
      }`,
    );
  const tree = () =>
    pg.scalar(
      `select coalesce(subtasks,'null'::jsonb) from public.tasks where id=${
        lit(task)
      }`,
    );
  const update = (value) =>
    pg.raw(
      `update public.tasks set subtasks=${
        value === null ? "null" : json(value)
      } where id=${lit(task)}`,
    );
  const adopt = async (value, generation) => {
    if (value === undefined) value = await tree();
    if (generation === undefined) generation = (await root()).task_generation;
    return pg.scalar(
      `select to_jsonb(taskfold_private.adopt_child_task_records(${lit(task)},${
        generation ? lit(generation) : "null"
      },${json(value)}))`,
    );
  };
  const decode = (value) =>
    pg.scalar(`select taskfold_private.decode_child_task_tree(${json(value)})`);
  // Reconstruct solely from the actual rows, using source only for null-vs-array.
  const reconstructed = async () => {
    const p = await projection(), rows = await records();
    assert.equal(p.state, "ready");
    const branch = (parent) =>
      rows.filter((r) => r.parent_key === parent).sort((a, b) =>
        a.sibling_order - b.sibling_order
      ).map((r) => ({
        ...r.fields,
        ...(r.children_kind === "absent" ? {} : {
          subtasks: r.children_kind === "null" ? null : branch(r.node_key),
        }),
      }));
    return p.source_tree === null ? null : branch(null);
  };
  check(
    "unadopted root has no projection",
    await pg.scalar(
      `select count(*)::int from taskfold_private.child_task_projections`,
    ),
    0,
  );
  await update([{ id: "untouched", title: "No automatic enrollment" }]);
  check(
    "ordinary edit does not enroll root",
    await pg.scalar(
      `select count(*)::int from taskfold_private.child_task_projections`,
    ),
    0,
  );
  check("stale snapshot refuses adoption", await adopt([]), "stale");
  check(
    "stale generation refuses adoption",
    await adopt(await tree(), randomUUID()),
    "stale",
  );
  check("stale adoption leaves no records", await records(), []);
  check(
    "missing root is explicit",
    await pg.scalar(
      `select to_jsonb(taskfold_private.adopt_child_task_records(${
        lit(randomUUID())
      },null,'[]'))`,
    ),
    "missing",
  );
  const rich = [
    {
      id: "root/one",
      title: "Preserve the entire child",
      description: "Line one\nLine two",
      completed: true,
      completed_at: "2026-10-01T09:00:00+00:00",
      priority: 1,
      due_date: "2026-10-31",
      due_time: "09:35:12",
      time_zone: "Europe/Copenhagen",
      scheduled_at: "2026-10-31T09:35:12+01:00",
      deadline_date: "2026-11-01",
      duration_minutes: 45,
      assigned_to: owner,
      labels: ["work", "draft"],
      is_heading: false,
      comments: [{ id: "comment", text: "Original discussion" }],
      attachments: [{ id: "file", url: "https://example.invalid/local-only" }],
      taskfold_completion_v1: { epoch: randomUUID(), version: 3 },
      reminder_specs: [{ future: true }],
      future_state: { keep: [false, null, 123.5] },
      subtasks: [{ id: "é", title: "Nested", subtasks: null }, {
        id: "case",
        title: "Absent children",
      }],
    },
    { id: "Case", title: "Distinct case is preserved", subtasks: [] },
  ];
  await update(rich);
  check("explicit reviewed adoption", await adopt(), "ready");
  check(
    "all fields order and child shapes roundtrip from records",
    await reconstructed(),
    rich,
  );
  const first = await records(), firstProjection = await projection();
  check(
    "NFC address retains literal identity",
    first.find((r) => r.node_key === "é").fields.id,
    "é",
  );
  check(
    "nested parent and raw path",
    first.find((r) => r.node_key === "é").identity_path,
    ["root/one", "é"],
  );
  check(
    "no synthetic positional IDs",
    first.map((r) => r.node_key).sort(),
    ["Case", "case", "root/one", "é"].sort(),
  );
  check("repeated adoption is idempotent", await adopt(), "ready");
  check(
    "idempotence preserves versions and incarnations",
    await records(),
    first,
  );
  check(
    "idempotence preserves root revision",
    await projection(),
    firstProjection,
  );
  const changed = structuredClone(rich);
  changed[0].subtasks[0].title = "Only this child changed";
  await update(changed);
  const edited = await records();
  check(
    "legacy write updates exact independent node",
    edited.find((r) => r.node_key === "é").revision,
    2,
  );
  check(
    "ancestor unchanged by descendant field edit",
    edited.find((r) => r.node_key === "root/one").revision,
    1,
  );
  check(
    "unrelated sibling retains identity and revision",
    edited.find((r) => r.node_key === "Case"),
    first.find((r) => r.node_key === "Case"),
  );
  check("field edit roundtrip", await reconstructed(), changed);
  const reordered = [changed[1], changed[0]];
  await update(reordered);
  check("root reorder is preserved", await reconstructed(), reordered);
  check(
    "reorder increments position version",
    (await records()).find((r) => r.node_key === "Case").revision,
    2,
  );
  const moved = structuredClone(reordered);
  const child = moved[1].subtasks.shift();
  moved[0].subtasks.push(child);
  await update(moved);
  check("reparent retains fields and new path", await reconstructed(), moved);
  check(
    "move preserves incarnation",
    (await records()).find((r) => r.node_key === "é").incarnation,
    first.find((r) => r.node_key === "é").incarnation,
  );
  const deleted = structuredClone(moved);
  deleted[0].subtasks = [];
  await update(deleted);
  check(
    "deleted child has no addressable stale row",
    (await records()).some((r) => r.node_key === "é"),
    false,
  );
  await update(moved);
  check(
    "restored key has new incarnation",
    (await records()).find((r) => r.node_key === "é").incarnation ===
      first.find((r) => r.node_key === "é").incarnation,
    false,
  );
  const previous = await records();
  await pg.raw(
    `begin;update public.tasks set subtasks='[]' where id=${
      lit(task)
    };rollback;`,
  );
  check("transaction rollback restores records", await records(), previous);
  check(
    "transaction rollback restores original tree",
    await reconstructed(),
    moved,
  );
  // A failing derived write must roll back the authoritative root too.
  await pg.raw(
    `create function taskfold_private.fixture_reject_child_projection() returns trigger language plpgsql set search_path='' as $$begin raise exception 'synthetic child storage failure';end$$;
 create trigger fixture_reject_child_projection before update on taskfold_private.child_task_records for each row execute function taskfold_private.fixture_reject_child_projection();`,
  );
  try {
    const failure = structuredClone(moved);
    failure[0].title = "Must roll back";
    await update(failure);
    assert.fail("expected failure");
  } catch (e) {
    if (e.code === undefined) throw e;
    check("derived storage failure aborts root save", e.code, "P0001");
  }
  await pg.raw(
    "drop trigger fixture_reject_child_projection on taskfold_private.child_task_records;drop function taskfold_private.fixture_reject_child_projection()",
  );
  check(
    "storage failure preserves both representations",
    await reconstructed(),
    moved,
  );
  check("storage failure preserves exact revisions", await records(), previous);
  const denied = async (role, expression) => {
    try {
      await pg.raw(`set role ${role};${expression}`);
      return "allowed";
    } catch (e) {
      return e.code;
    }
  };
  for (const role of ["anon", "authenticated", "service_role"]) {
    check(
      role + " cannot read records",
      await denied(role, "select * from taskfold_private.child_task_records"),
      "42501",
    );
    check(
      role + " cannot read snapshots",
      await denied(
        role,
        "select * from taskfold_private.child_task_projections",
      ),
      "42501",
    );
    check(
      role + " cannot enroll roots",
      await denied(
        role,
        `select taskfold_private.adopt_child_task_records(${
          lit(task)
        },null,'[]')`,
      ),
      "42501",
    );
    check(
      role + " cannot call sync",
      await denied(
        role,
        `select taskfold_private.sync_child_task_records(${
          lit(task)
        },null,'[]')`,
      ),
      "42501",
    );
    check(
      role + " cannot decode through API",
      await denied(
        role,
        `select taskfold_private.decode_child_task_tree('[]')`,
      ),
      "42501",
    );
    check(
      role + " cannot invoke trigger directly",
      await denied(
        role,
        "select taskfold_private.refresh_child_task_records()",
      ),
      "42501",
    );
  }
  await pg.raw(
    `set role authenticated;set request.jwt.claim.sub=${
      lit(other)
    };update public.tasks set subtasks='[]' where id=${lit(task)}`,
  );
  check(
    "inaccessible root update cannot alter projection",
    await records(),
    previous,
  );
  const nativeEdit = structuredClone(moved);
  nativeEdit[0].title = "Authorized existing write";
  await pg.raw(
    `set role authenticated;set request.jwt.claim.sub=${
      lit(owner)
    };update public.tasks set subtasks=${json(nativeEdit)} where id=${
      lit(task)
    }`,
  );
  check(
    "authorized RLS write synchronizes without private grants",
    await reconstructed(),
    nativeEdit,
  );
  check("decoder retains JSON null root", await decode(null), {
    state: "ready",
    nodes: [],
  });
  const invalidCases = [
    ["root_shape", {}],
    ["identity", ["legacy text"]],
    ["identity", [{ title: "Missing id" }]],
    ["identity", [{ id: 17 }]],
    ["identity", [{ id: "" }]],
    ["identity", [{ id: "x".repeat(129) }]],
    ["duplicate_identity", [{ id: "a" }, {
      id: "parent",
      subtasks: [{ id: "a" }],
    }]],
    ["duplicate_identity", [{ id: "é" }, { id: "e\u0301" }]],
    ["children_shape", [{ id: "a", subtasks: { future: true } }]],
  ];
  for (const [i, [issue, value]] of invalidCases.entries()) {
    check("decoder rejects ambiguous source " + i, await decode(value), {
      state: "review",
      issue,
    });
  }
  let deep = { id: "leaf" };
  for (let i = 0; i < 24; i++) deep = { id: "depth-" + i, subtasks: [deep] };
  check("depth is bounded", (await decode([deep])).issue, "depth_limit");
  check(
    "node count is bounded",
    (await decode(Array.from({ length: 1001 }, (_, i) => ({ id: "n" + i }))))
      .issue,
    "node_limit",
  );
  check(
    "1000 independent records accepted",
    (await decode(Array.from({ length: 1000 }, (_, i) => ({ id: "n" + i }))))
      .nodes.length,
    1000,
  );
  check(
    "normalization preserves decomposed raw identity",
    (await decode([{ id: "e\u0301" }])).nodes[0].fields.id,
    "e\u0301",
  );
  await update([{ id: "dup" }, { id: "dup" }]);
  check("invalid legacy update stays saved", await tree(), [{ id: "dup" }, {
    id: "dup",
  }]);
  check(
    "invalid legacy update requires review",
    (await projection()).state,
    "review",
  );
  check("review removes all stale addressable rows", await records(), []);
  check(
    "review stores exact unsupported source",
    (await projection()).source_tree,
    [{ id: "dup" }, { id: "dup" }],
  );
  await update(nativeEdit);
  check(
    "valid correction recovers losslessly",
    await reconstructed(),
    nativeEdit,
  );
  check(
    "review recovery creates fresh incarnations",
    (await records()).every((r) =>
      !previous.some((p) => p.incarnation === r.incarnation)
    ),
    true,
  );
  for (
    const value of [null, [], [{ id: "blank", subtasks: [] }], [{
      id: "outer",
      subtasks: [{ id: "null", subtasks: null }],
    }], [{ id: "absent" }]]
  ) {
    await update(value);
    check(
      "null empty absent roundtrip " + JSON.stringify(value),
      await reconstructed(),
      value,
    );
  }
  // Root locking serializes adoption with an actual concurrent legacy edit.
  await update(rich);
  const beforeRace = await root();
  const holder = await pg.hold(
    `select id from public.tasks where id=${
      lit(task)
    } for update;update public.tasks set subtasks=${json(changed)} where id=${
      lit(task)
    };`,
  );
  let pending;
  try {
    pending = pg.value(
      `to_jsonb(taskfold_private.adopt_child_task_records(${lit(task)},${
        lit(beforeRace.task_generation)
      },${json(rich)}))`,
      { role: "postgres", app: "taskfold-child-adoption-race" },
    );
    await pg.waitForLock("taskfold-child-adoption-race", holder.pid);
    await holder.release("commit");
    check(
      "waiting adoption rejects concurrent source change",
      (await pending).value,
      "stale",
    );
  } finally {
    await holder.release("rollback");
    if (pending) await pending;
  }
  check(
    "winning concurrent edit and records agree",
    await reconstructed(),
    changed,
  );
  const oldGeneration = (await root()).task_generation,
    oldRecords = await records();
  await pg.raw(`delete from public.tasks where id=${lit(task)}`);
  check(
    "root deletion cascades projection",
    await pg.scalar(
      `select count(*)::int from taskfold_private.child_task_projections where task_id=${
        lit(task)
      }`,
    ),
    0,
  );
  check("root deletion cascades children", await records(), []);
  await pg.raw(
    `insert into public.tasks(id,user_id,title,subtasks) values(${lit(task)},${
      lit(owner)
    },'Restored synthetic root',${json(rich)})`,
  );
  check(
    "reused root gets new generation",
    (await root()).task_generation === oldGeneration,
    false,
  );
  check(
    "restored root is not automatically enrolled",
    await pg.scalar(
      `select count(*)::int from taskfold_private.child_task_projections where task_id=${
        lit(task)
      }`,
    ),
    0,
  );
  check(
    "old root generation cannot adopt restored tree",
    await adopt(rich, oldGeneration),
    "stale",
  );
  check("new generation may explicitly adopt", await adopt(), "ready");
  check(
    "restored root cannot reuse old child incarnations",
    (await records()).some((r) =>
      oldRecords.some((p) => p.incarnation === r.incarnation)
    ),
    false,
  );
  check("restored root roundtrip", await reconstructed(), rich);
  check(
    "no customer role has table privileges",
    await pg.scalar(
      `select to_jsonb(not exists(select 1 from unnest(array['anon','authenticated','service_role']) role cross join unnest(array['taskfold_private.child_task_projections','taskfold_private.child_task_records']) rel where has_table_privilege(role,rel,'SELECT,INSERT,UPDATE,DELETE')))`,
    ),
    true,
  );
  check(
    "no customer role has helper execute privileges",
    await pg.scalar(
      `select to_jsonb(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join unnest(array['anon','authenticated','service_role']) role where n.nspname='taskfold_private' and p.proname in ('decode_child_task_tree','sync_child_task_records','adopt_child_task_records','refresh_child_task_records') and has_function_privilege(role,p.oid,'EXECUTE')))`,
    ),
    true,
  );
  check(
    "only trigger helper elevates with a fixed path",
    await pg.scalar(
      `select to_jsonb(bool_and(p.prosecdef=(p.proname='refresh_child_task_records') and p.proconfig=array['search_path=""'])) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='taskfold_private' and p.proname in ('decode_child_task_tree','sync_child_task_records','adopt_child_task_records','refresh_child_task_records')`,
    ),
    true,
  );
  check(
    "RLS is enabled on both private tables",
    await pg.scalar(
      `select to_jsonb(bool_and(relrowsecurity)) from pg_class where oid in ('taskfold_private.child_task_projections'::regclass,'taskfold_private.child_task_records'::regclass)`,
    ),
    true,
  );
  // Null generations occur on genuine pre-generation roots; don't force a UUID.
  await pg.raw(
    `begin;alter table public.tasks disable trigger taskfold_guard_generation;update public.tasks set task_generation=null where id=${
      lit(task)
    };alter table public.tasks enable trigger taskfold_guard_generation;commit;`,
  );
  check(
    "legacy null generation is represented",
    (await projection()).task_generation,
    null,
  );
  check("legacy null generation stays lossless", await reconstructed(), rich);
  check(
    "legacy null generation adoption is idempotent",
    await adopt(rich, null),
    "ready",
  );
  report.advisors = await pg.advisors();
  const keys = new Set(report.baselineAdvisors.result.map((x) => x.cache_key));
  check(
    "no added advisor findings",
    report.advisors.result.filter((x) => !keys.has(x.cache_key)),
    [],
  );
  report.serverVersion = pg.serverVersion;
} finally {
  report.containerRemoved = await pg.close();
}
report.checkCount = Object.keys(report.checks).length;
if (process.argv[2]) {
  await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
}
console.log(
  JSON.stringify({
    checks: report.checkCount,
    containerRemoved: report.containerRemoved,
  }),
);
