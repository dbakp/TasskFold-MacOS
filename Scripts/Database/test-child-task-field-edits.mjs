import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadWorkflowRunSchema } from "./team-workflow-run-schema.mjs";
import { loadChildTaskRecordsSchema } from "./child-task-records-schema.mjs";
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
const sql = await readFile(
  new URL(
    "../../supabase/migrations/20261029005723_child_task_field_edits.sql",
    import.meta.url,
  ),
  "utf8",
);
const report = {
  checks: {},
  migrationSHA256: createHash("sha256").update(sql).digest("hex"),
  deployed: false,
  clientWrites: false,
};
const check = (n, a, e) => {
  assert.deepEqual(a, e, n);
  report.checks[n] = true;
};
const pg = await createPostgresFixture({ advisors: true });
try {
  await loadWorkflowRunSchema(pg.raw, { taskTypes: true });
  await loadChildTaskRecordsSchema(pg.raw);
  await pg.raw(
    await readFile(
      new URL(
        "../../supabase/migrations/20261029001127_child_task_record_reads.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const people = Object.fromEntries(
    ["owner", "writer", "viewer", "outside"].map(
      (k) => [k, { id: randomUUID(), session: randomUUID() }],
    ),
  );
  for (const u of Object.values(people)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${
        lit(u.id + "@example.invalid")
      },now());insert into public.profiles(user_id) values(${
        lit(u.id)
      });insert into auth.sessions(id,user_id) values(${lit(u.session)},${
        lit(u.id)
      });`,
    );
  }
  const project = randomUUID(),
    task = randomUUID(),
    team = randomUUID(),
    tp = randomUUID(),
    tt = randomUUID();
  const node = (id, children = []) => ({
    id,
    title: "Original " + id,
    description: "Original notes",
    priority: 4,
    completed: false,
    completed_at: null,
    subtasks: children,
    taskfold_completion_v1: { epoch: randomUUID(), version: 0 },
    comments: [{ id: "discussion-" + id, text: "Preserved discussion" }],
    attachments: [{
      id: "file-" + id,
      url: "https://example.invalid/synthetic",
    }],
    future: { retain: [null, false, "original"] },
  });
  const source = [node("a", [node("nested")]), node("b")];
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${lit(project)},${
      lit(people.owner.id)
    },'Synthetic personal project');insert into public.tasks(id,user_id,project_id,title,subtasks) values(${
      lit(task)
    },${lit(people.owner.id)},${lit(project)},'Synthetic root',${
      json(source)
    });select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${
      lit(task)
    };`,
  );
  const row = async (id = task) =>
    pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(id)}`);
  const records = async (id = task) =>
    pg.scalar(
      `select jsonb_agg(to_jsonb(r) order by node_key) from taskfold_private.child_task_records r where task_id=${
        lit(id)
      }`,
    );
  // Preexisting records with a higher revision require conservative field fences.
  const before = await records();
  const legacy = structuredClone(source);
  legacy[0].title = "Legacy title before migration";
  await pg.raw(
    `update public.tasks set subtasks=${json(legacy)} where id=${lit(task)}`,
  );
  report.baselineAdvisors = await pg.advisors();
  await pg.raw(sql);
  const run = (
    body,
    {
      who = "owner",
      fn = "public.taskfold_edit_child_task",
      app = "taskfold-child-edit",
      session = people[who].session,
    } = {},
  ) =>
    pg.scalar(
      `begin;set application_name=${
        lit(app)
      };create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated;set local role authenticated;set local request.jwt.claim.sub=${
        lit(people[who].id)
      };set local request.jwt.claims=${
        lit(JSON.stringify({ sub: people[who].id, session_id: session }))
      };do $edit$begin begin insert into result values(${fn}(${
        json({ account: people[who].id, ...body })
      }),null,null);exception when others then insert into result values(null,sqlstate,left(sqlerrm,150));end;end$edit$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`,
    );
  const command = async (
    key,
    changes,
    { id = task, old = null, q = randomUUID() } = {},
  ) => {
    const t = await row(id),
      n = old ?? (await records(id)).find((n) => n.node_key === key);
    return {
      protocol: 1,
      request_id: q,
      task_id: id,
      task_generation: t.task_generation,
      project_id: t.project_id,
      node_key: key,
      incarnation: n.incarnation,
      revision: n.revision,
      changes,
    };
  };
  let initial = await command("a", { title: "First change" });
  check(
    "write candidate disabled by default",
    (await run(initial)).code,
    "PT503",
  );
  await pg.raw(
    "update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true",
  );
  check(
    "backfill fences existing field at current revision",
    (await records()).find((n) => n.node_key === "a").field_versions.title,
    2,
  );
  check(
    "old pre-migration field baseline refuses",
    (await run(
      await command("a", { title: "Too old" }, {
        old: before.find((n) => n.node_key === "a"),
      }),
    )).code,
    "PT409",
  );
  const sameBaseline = (await records()).find((n) => n.node_key === "a");
  const first = await command("a", { title: "Edited title" }, {
      old: sameBaseline,
    }),
    second = await command("a", { description: "Independent notes" }, {
      old: sameBaseline,
    });
  const one = await run(first);
  check("personal child field edit succeeds", one.code, null);
  check("first edit advances node revision", one.value.revision, 3);
  check(
    "disjoint field on same stale node succeeds",
    (await run(second)).code,
    null,
  );
  let current = await row();
  check("disjoint edits retain both values", [
    current.subtasks[0].title,
    current.subtasks[0].description,
  ], ["Edited title", "Independent notes"]);
  check(
    "nested branch and opaque history unchanged",
    current.subtasks[0].subtasks,
    source[0].subtasks,
  );
  check(
    "unrelated root fields unchanged",
    [current.title, current.project_id],
    ["Synthetic root", project],
  );
  check("opaque child fields unchanged", [
    current.subtasks[0].comments,
    current.subtasks[0].attachments,
    current.subtasks[0].future,
  ], [source[0].comments, source[0].attachments, source[0].future]);
  const replay = await run(first);
  check("lost reply returns recorded receipt", replay.value.replayed, true);
  check("receipt retains original result revision", replay.value.revision, 3);
  const afterReplay = await row();
  check(
    "retry cannot overwrite later field",
    afterReplay.subtasks[0].description,
    "Independent notes",
  );
  check(
    "changed intent cannot reuse request identity",
    (await run({ ...first, changes: { title: "Forged reuse" } })).code,
    "PT409",
  );
  check(
    "same field stale edit refuses",
    (await run(
      await command("a", { title: "Stale edit" }, { old: sameBaseline }),
    )).code,
    "PT409",
  );
  const abaBaseline = (await records()).find((n) => n.node_key === "a");
  let tree = structuredClone((await row()).subtasks);
  tree[0].title = "Intervening title";
  await pg.raw(
    `update public.tasks set subtasks=${json(tree)} where id=${lit(task)}`,
  );
  tree[0].title = "Edited title";
  await pg.raw(
    `update public.tasks set subtasks=${json(tree)} where id=${lit(task)}`,
  );
  check(
    "edit after title changed and returned still refuses",
    (await run(
      await command("a", { title: "ABA stale edit" }, { old: abaBaseline }),
    )).code,
    "PT409",
  );
  check(
    "unrelated child old revision still succeeds",
    (await run(
      await command("b", { title: "Independent sibling" }, {
        old: before.find((n) => n.node_key === "b"),
      }),
    )).code,
    null,
  );
  const saved = await row();
  for (
    const key of [
      "completed",
      "completed_at",
      "subtasks",
      "id",
      "is_heading",
      "comments",
      "attachments",
      "future",
      "taskfold_completion_v1",
    ]
  ) {
    check(
      "separate action required for " + key,
      (await run(await command("a", { [key]: null }))).code,
      "22023",
    );
  }
  for (
    const [key, value] of [
      ["priority", 0],
      ["duration_minutes", -1],
      ["title", ""],
      ["time_zone", "not/a-zone"],
      ["description", {}],
    ]
  ) {
    check(
      "invalid value " + key,
      (await run(await command("a", { [key]: value }))).code,
      "22023",
    );
  }
  check(
    "failed validations preserve root",
    (await row()).subtasks,
    saved.subtasks,
  );
  check(
    "outsider cannot prepare plaintext plan",
    (await run(await command("a", { title: "Denied" }), {
      who: "outside",
      fn: "taskfold_private.child_task_edit_prepare",
    })).code,
    "42501",
  );
  check(
    "outsider public edit denied",
    (await run(await command("a", { title: "Denied" }), { who: "outside" }))
      .code,
    "42501",
  );
  check(
    "missing session denied",
    (await run(await command("a", { title: "Denied" }), {
      session: randomUUID(),
    })).code,
    "28000",
  );
  check(
    "wrong project cannot edit",
    (await run({
      ...await command("a", { title: "Denied" }),
      project_id: randomUUID(),
    })).code,
    "PT409",
  );
  check(
    "wrong generation cannot edit",
    (await run({
      ...await command("a", { title: "Denied" }),
      task_generation: randomUUID(),
    })).code,
    "PT409",
  );
  const withoutPrep = await command("a", { title: "No preparation" });
  check(
    "direct finish cannot invent receipt",
    (await run(withoutPrep, { fn: "taskfold_private.child_task_edit_finish" }))
      .code,
    "PT409",
  );
  const expiredPrep = await command("a", { title: "Abandoned preparation" });
  check(
    "private preparation can only plan",
    (await run(expiredPrep, { fn: "taskfold_private.child_task_edit_prepare" }))
      .code,
    null,
  );
  check(
    "preparation alone never writes",
    (await row()).subtasks,
    saved.subtasks,
  );
  check(
    "different transaction cannot finish",
    (await run(expiredPrep, { fn: "taskfold_private.child_task_edit_finish" }))
      .code,
    "PT409",
  );
  // A failed receipt write rolls the root, derived fields and team RPC receipt back.
  await pg.raw(
    `create function taskfold_private.fixture_fail_child_receipt() returns trigger language plpgsql set search_path='' as $$begin raise exception 'synthetic receipt failure';end$$;create trigger fixture_fail_child_receipt before insert on taskfold_private.child_task_edit_receipts for each row execute function taskfold_private.fixture_fail_child_receipt();`,
  );
  const rollback = await command("a", { description: "Must roll back" }),
    beforeFailure = await records();
  check("receipt failure aborts mutation", (await run(rollback)).code, "P0001");
  check(
    "receipt failure rolls back task",
    (await row()).subtasks,
    saved.subtasks,
  );
  check(
    "receipt failure rolls back field revisions",
    await records(),
    beforeFailure,
  );
  await pg.raw(
    "drop trigger fixture_fail_child_receipt on taskfold_private.child_task_edit_receipts;drop function taskfold_private.fixture_fail_child_receipt()",
  );
  check(
    "same request retries after rolled-back failure",
    (await run(rollback)).code,
    null,
  );
  // Actual simultaneous commands serialize at the root and preserve disjoint fields.
  const n = (await records()).find((n) => n.node_key === "b"),
    left = await command("b", { title: "Concurrent title" }, { old: n }),
    right = await command("b", { description: "Concurrent notes" }, { old: n });
  const blocker = await pg.hold(
    `select id from public.tasks where id=${lit(task)} for update`,
  );
  let l, r;
  try {
    l = run(left, { app: "taskfold-child-edit-left" });
    r = run(right, { app: "taskfold-child-edit-right" });
    const waits = await Promise.all([
      pg.waitForLock("taskfold-child-edit-left"),
      pg.waitForLock("taskfold-child-edit-right"),
    ]);
    report.concurrentLockGraph = { holder: blocker.pid, waits };
    check(
      "queued edits block only on holder or each other",
      waits.every((w) =>
        w.blockers.length > 0 &&
        w.blockers.every((p) =>
          [blocker.pid, ...waits.map((w) => w.pid)].includes(p)
        )
      ),
      true,
    );
    check(
      "queued edit graph reaches root holder",
      waits.some((w) => w.blockers.includes(blocker.pid)),
      true,
    );
    await blocker.release("commit");
    check("concurrent first field accepted", (await l).code, null);
    check("concurrent second field accepted", (await r).code, null);
  } finally {
    await blocker.release("rollback");
    if (l) await l;
    if (r) await r;
  }
  check("concurrent values both remain", [
    (await row()).subtasks[1].title,
    (await row()).subtasks[1].description,
  ], ["Concurrent title", "Concurrent notes"]);
  // Simultaneous same-field changes need one winner, not last-writer wins.
  const same = (await records()).find((n) => n.node_key === "b"),
    conflicts = [
      await command("b", { title: "First competing title" }, { old: same }),
      await command("b", { title: "Second competing title" }, { old: same }),
    ];
  const conflictHolder = await pg.hold(
    `select id from public.tasks where id=${lit(task)} for update`,
  );
  let c1, c2;
  try {
    c1 = run(conflicts[0], { app: "taskfold-child-conflict-one" });
    c2 = run(conflicts[1], { app: "taskfold-child-conflict-two" });
    await Promise.all([
      pg.waitForLock("taskfold-child-conflict-one"),
      pg.waitForLock("taskfold-child-conflict-two"),
    ]);
    await conflictHolder.release("commit");
    const replies = await Promise.all([c1, c2]);
    check(
      "same field has exactly one winner",
      replies.map((r) => r.code ?? "OK").sort(),
      ["OK", "PT409"],
    );
    check(
      "same-field conflict increments only once",
      (await records()).find((n) => n.node_key === "b").revision,
      same.revision + 1,
    );
  } finally {
    await conflictHolder.release("rollback");
    if (c1) await c1;
    if (c2) await c2;
  }
  const duplicate = await command("b", { description: "One exact request" }),
    duplicateBefore = (await records()).find((n) => n.node_key === "b");
  const duplicateHolder = await pg.hold(
    `select id from public.tasks where id=${lit(task)} for update`,
  );
  let d1, d2;
  try {
    d1 = run(duplicate, { app: "taskfold-child-duplicate-one" });
    d2 = run(duplicate, { app: "taskfold-child-duplicate-two" });
    await Promise.all([
      pg.waitForLock("taskfold-child-duplicate-one"),
      pg.waitForLock("taskfold-child-duplicate-two"),
    ]);
    await duplicateHolder.release("commit");
    const replies = await Promise.all([d1, d2]);
    check(
      "concurrent duplicate requests both confirm",
      replies.map((r) => r.code),
      [null, null],
    );
    check(
      "concurrent duplicate executes once",
      replies.map((r) => r.value.replayed).sort(),
      [false, true],
    );
    check(
      "duplicate advances node once",
      (await records()).find((n) => n.node_key === "b").revision,
      duplicateBefore.revision + 1,
    );
  } finally {
    await duplicateHolder.release("rollback");
    if (d1) await d1;
    if (d2) await d2;
  }
  const noop = await command("b", { description: "One exact request" }),
    noopBefore = await records();
  check("explicit no-op can be certified", (await run(noop)).code, null);
  check("no-op preserves field revisions", await records(), noopBefore);
  const parentBefore = (await records()).find((n) => n.node_key === "a");
  check(
    "nested node edit succeeds",
    (await run(
      await command("nested", { description: "Nested independent edit" }),
    )).code,
    null,
  );
  check(
    "descendant field edit leaves parent revision",
    (await records()).find((n) => n.node_key === "a").revision,
    parentBefore.revision,
  );
  const beforeRemoval = (await records()).find((n) => n.node_key === "a");
  let removed = (await row()).subtasks;
  const description = removed[0].description;
  delete removed[0].description;
  await pg.raw(
    `update public.tasks set subtasks=${json(removed)} where id=${lit(task)}`,
  );
  check(
    "removed field retains its change fence",
    (await records()).find((n) => n.node_key === "a").field_versions
      .description > beforeRemoval.revision,
    true,
  );
  removed[0].description = description;
  await pg.raw(
    `update public.tasks set subtasks=${json(removed)} where id=${lit(task)}`,
  );
  check(
    "remove and restore cannot revive stale field edit",
    (await run(
      await command("a", { description: "Stale removed field" }, {
        old: beforeRemoval,
      }),
    )).code,
    "PT409",
  );
  const expiring = await command("b", { title: "Must not apply after expiry" }),
    expiryBefore = await row();
  const expiryHolder = await pg.hold(
    `select id from public.tasks where id=${lit(task)} for update`,
  );
  let expiryPending;
  try {
    await pg.raw(
      `update auth.sessions set not_after=clock_timestamp()+interval '500 milliseconds' where id=${
        lit(people.owner.session)
      }`,
    );
    expiryPending = run(expiring, { app: "taskfold-child-expiry" });
    await pg.waitForLock("taskfold-child-expiry");
    await new Promise((r) => setTimeout(r, 650));
    await expiryHolder.release("commit");
    check(
      "session expiring during root wait refuses edit",
      (await expiryPending).code,
      "28000",
    );
    check(
      "expiry wait leaves source unchanged",
      (await row()).subtasks,
      expiryBefore.subtasks,
    );
  } finally {
    await expiryHolder.release("rollback");
    if (expiryPending) await expiryPending;
    await pg.raw(
      `update auth.sessions set not_after=null where id=${
        lit(people.owner.session)
      }`,
    );
  }
  // Remove and recreate the same key through the existing JSON bridge.
  const priorNode = (await records()).find((n) => n.node_key === "a");
  tree = (await row()).subtasks;
  const priorTree = tree[0];
  await pg.raw(
    `update public.tasks set subtasks=${json(tree.slice(1))} where id=${
      lit(task)
    }`,
  );
  await pg.raw(
    `update public.tasks set subtasks=${
      json([priorTree, ...tree.slice(1)])
    } where id=${lit(task)}`,
  );
  check(
    "old child incarnation cannot edit recreated key",
    (await run(
      await command("a", { title: "Old incarnation" }, { old: priorNode }),
    )).code,
    "PT409",
  );
  await pg.raw(
    `update public.projects set is_archived=true where id=${lit(project)}`,
  );
  check(
    "archive blocks new edits",
    (await run(await command("a", { title: "Archived" }))).code,
    "PT409",
  );
  check("archive also blocks write replay", (await run(first)).code, "PT409");
  await pg.raw(
    `update public.projects set is_archived=false where id=${lit(project)}`,
  );
  // Canonical team tree with completion epochs; no completion authority is added.
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(people.owner.id)
    },'Synthetic child team');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(people.owner.id)},'admin'),(${lit(team)},${
      lit(people.writer.id)
    },'member'),(${lit(team)},${
      lit(people.viewer.id)
    },'guest');insert into public.projects(id,user_id,name) values(${lit(tp)},${
      lit(people.owner.id)
    },'Synthetic team project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
      lit(tp)
    },${
      lit(team)
    },'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${
      lit(tp)
    },${lit(team)},${lit(people.writer.id)},'editor'),(${lit(tp)},${
      lit(team)
    },${
      lit(people.viewer.id)
    },'viewer');insert into public.tasks(id,user_id,project_id,title,subtasks) values(${
      lit(tt)
    },${lit(people.owner.id)},${lit(tp)},'Synthetic team root',${
      json(source)
    });select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${
      lit(tt)
    };`,
  );
  const teamBody = await command("a", { title: "Team title" }, { id: tt });
  check(
    "team write gate still applies",
    (await run(teamBody, { who: "writer" })).code,
    "PT503",
  );
  await pg.raw(
    "update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true",
  );
  const teamStart = (await records(tt)).find((n) => n.node_key === "a");
  check(
    "team editor child edit succeeds",
    (await run(teamBody, { who: "writer" })).code,
    null,
  );
  check(
    "team disjoint field succeeds through existing team RPC",
    (await run(
      await command("a", { description: "Team notes" }, {
        id: tt,
        old: teamStart,
      }),
      { who: "writer" },
    )).code,
    null,
  );
  check("team fields preserve metadata", [
    (await row(tt)).subtasks[0].title,
    (await row(tt)).subtasks[0].description,
    (await row(tt)).subtasks[0].future,
  ], ["Team title", "Team notes", source[0].future]);
  check(
    "team viewer cannot write",
    (await run(await command("b", { title: "Viewer cannot" }, { id: tt }), {
      who: "viewer",
    })).code,
    "42501",
  );
  check(
    "team outsider cannot prepare",
    (await run(await command("b", { title: "Outside cannot" }, { id: tt }), {
      who: "outside",
      fn: "taskfold_private.child_task_edit_prepare",
    })).code,
    "42501",
  );
  check(
    "team same-field stale edit refuses",
    (await run(
      await command("a", { title: "Stale team title" }, {
        id: tt,
        old: teamStart,
      }),
      { who: "writer" },
    )).code,
    "PT409",
  );
  const shared = (await records(tt)).find((n) => n.node_key === "b"),
    sharedOwner = await command("b", { title: "Owner shared title" }, {
      id: tt,
      old: shared,
    }),
    sharedWriter = await command("b", { description: "Writer shared notes" }, {
      id: tt,
      old: shared,
    });
  const sharedHolder = await pg.hold(
    `select id from public.tasks where id=${lit(tt)} for update`,
  );
  let ownerPending, writerPending;
  try {
    ownerPending = run(sharedOwner, {
      who: "owner",
      app: "taskfold-child-team-owner",
    });
    writerPending = run(sharedWriter, {
      who: "writer",
      app: "taskfold-child-team-writer",
    });
    await Promise.all([
      pg.waitForLock("taskfold-child-team-owner"),
      pg.waitForLock("taskfold-child-team-writer"),
    ]);
    await sharedHolder.release("commit");
    check(
      "concurrent team owner edit accepted",
      (await ownerPending).code,
      null,
    );
    check(
      "concurrent distinct team actor edit accepted",
      (await writerPending).code,
      null,
    );
  } finally {
    await sharedHolder.release("rollback");
    if (ownerPending) await ownerPending;
    if (writerPending) await writerPending;
  }
  check("two team actors retain both fields", [
    (await row(tt)).subtasks[1].title,
    (await row(tt)).subtasks[1].description,
  ], ["Owner shared title", "Writer shared notes"]);
  const teamFailure = await command("b", { priority: 2 }, { id: tt }),
    teamBefore = await row(tt),
    teamRecordsBefore = await records(tt);
  await pg.raw(
    `create function taskfold_private.fixture_fail_child_receipt() returns trigger language plpgsql set search_path='' as $$begin raise exception 'synthetic receipt failure';end$$;create trigger fixture_fail_child_receipt before insert on taskfold_private.child_task_edit_receipts for each row execute function taskfold_private.fixture_fail_child_receipt();`,
  );
  check(
    "team receipt failure aborts edit",
    (await run(teamFailure)).code,
    "P0001",
  );
  check(
    "team receipt failure restores source",
    (await row(tt)).subtasks,
    teamBefore.subtasks,
  );
  check(
    "team receipt failure restores field metadata",
    await records(tt),
    teamRecordsBefore,
  );
  check(
    "upstream team receipt also rolls back",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_task_edits where team_id=${
        lit(team)
      } and request_id=${lit(teamFailure.request_id)}`,
    ),
    0,
  );
  await pg.raw(
    "drop trigger fixture_fail_child_receipt on taskfold_private.child_task_edit_receipts;drop function taskfold_private.fixture_fail_child_receipt()",
  );
  check(
    "team failed request may safely retry",
    (await run(teamFailure)).code,
    null,
  );
  const otherAccountCommand = await command("b", {
    description: "Must not cross accounts",
  }, { id: tt });
  check(
    "another authorized account cannot route saved command",
    (await run({ ...otherAccountCommand, account: people.owner.id }, {
      who: "writer",
    })).code,
    "42501",
  );
  check(
    "account binding is required",
    (await run({
      ...await command("b", { description: "Missing account" }, { id: tt }),
      account: undefined,
    })).code,
    "22023",
  );
  const teamReplay = await run(teamBody, { who: "writer" });
  check(
    "team lost reply returns durable child receipt",
    teamReplay.value.replayed,
    true,
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where project_id=${
      lit(tp)
    } and user_id=${lit(people.writer.id)}`,
  );
  check(
    "revoked editor cannot replay",
    (await run(teamBody, { who: "writer" })).code,
    "42501",
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    for (
      const table of [
        "child_task_edit_receipts",
        "child_task_edit_preparations",
      ]
    ) {
      check(
        role + " cannot read " + table,
        await pg.scalar(
          `select to_jsonb(has_table_privilege(${lit(role)},${
            lit("taskfold_private." + table)
          },'SELECT'))`,
        ),
        false,
      );
    }
  }
  const largeBody = await command("a", {
      title: "Do not expand oversized source",
    }),
    largeBefore = await row();
  await pg.raw(
    `update public.tasks set subtasks=jsonb_set(subtasks,'{1,description}',to_jsonb(repeat('x',2000001))) where id=${
      lit(task)
    }`,
  );
  check(
    "oversized source refuses compact child edit",
    (await run(largeBody)).code,
    "54000",
  );
  await pg.raw(
    `update public.tasks set subtasks=${json(largeBefore.subtasks)} where id=${
      lit(task)
    }`,
  );
  // The internal column must not change the strict protocol-1 client envelope.
  const wire = await pg.scalar(
    `set role authenticated;set request.jwt.claim.sub=${
      lit(people.owner.id)
    };set request.jwt.claims=${
      lit(
        JSON.stringify({
          sub: people.owner.id,
          session_id: people.owner.session,
        }),
      )
    };select public.taskfold_read_child_tasks(${lit(task)},${
      lit((await row()).task_generation)
    })`,
  );
  check(
    "private field versions absent from read protocol",
    wire.records.some((n) => Object.hasOwn(n, "field_versions")),
    false,
  );
  report.wireFixture = {
    account: people.owner.id,
    root: await row(),
    response: wire,
  };
  check(
    "only deliberate abandoned preparation remains",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.child_task_edit_preparations`,
    ),
    1,
  );
  report.advisors = await pg.advisors();
  const keys = new Set(report.baselineAdvisors.result.map((x) => x.cache_key));
  check(
    "no added advisor findings",
    report.advisors.result.filter((x) => !keys.has(x.cache_key)),
    [],
  );
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
