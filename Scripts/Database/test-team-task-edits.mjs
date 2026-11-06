import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamProjectSchema } from "./team-project-schema.mjs";
const migration = "20261024040403_team_task_edits.sql";
const report = {
  checks: {},
  deployed: false,
  nativeRolloutEnabled: false,
  hostedAcceptanceClaimed: false,
  realDataChanged: false,
};
function check(name, actual, expected) {
  assert.deepEqual(actual, expected, name);
  report.checks[name] = true;
}
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
const people = Object.fromEntries(
  ["owner", "editor", "viewer", "guest", "outsider"].map(
    (k) => [k, { id: randomUUID(), session: randomUUID() }],
  ),
);
const team = randomUUID(),
  project = randomUUID(),
  hidden = randomUUID(),
  task = randomUUID(),
  generation = randomUUID(),
  personal = randomUUID();
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadTeamProjectSchema(pg.raw);
  const sql = await readFile(
    new URL("../../supabase/migrations/" + migration, import.meta.url),
    "utf8",
  );
  await pg.raw(sql);
  report.migrationSHA256 = createHash("sha256").update(sql).digest("hex");
  if (process.env.TASKFOLD_TEAM_LIFECYCLE_REGRESSION === "1") {
    const { loadTeamTaskLifecycle, teamTaskLifecycleMigration } = await import(
      "./team-task-schema.mjs"
    );
    await loadTeamTaskLifecycle(pg.raw, { base: false });
    report.lifecycleMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamTaskLifecycleMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (process.env.TASKFOLD_TEAM_CONVERSATION_REGRESSION === "1") {
    if (process.env.TASKFOLD_TEAM_LIFECYCLE_REGRESSION !== "1") {
      throw new Error("Conversation regression requires lifecycle");
    }
    const { loadTeamConversationSchema, teamConversationMigration } =
      await import("./team-conversation-schema.mjs");
    await loadTeamConversationSchema(pg.raw, { base: false });
    report.conversationMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamConversationMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (process.env.TASKFOLD_TEAM_BATCH_REGRESSION === "1") {
    const { loadTeamBatchSchema, teamBatchMigration } = await import(
      "./team-batch-schema.mjs"
    );
    await loadTeamBatchSchema(pg.raw, { base: false });
    report.batchMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamBatchMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (process.env.TASKFOLD_TEAM_PLANNING_REGRESSION === "1") {
    if (process.env.TASKFOLD_TEAM_BATCH_REGRESSION !== "1") {
      throw new Error("Planning regression requires batch schema");
    }
    const sql = await readFile(
      new URL(
        "../../supabase/migrations/20261024054229_team_task_planning_edits.sql",
        import.meta.url,
      ),
      "utf8",
    );
    await pg.raw(sql);
    report.planningMigrationSHA256 = createHash("sha256").update(sql).digest(
      "hex",
    );
  }
  if (process.env.TASKFOLD_TEAM_CHECKLIST_REGRESSION === "1") {
    if (process.env.TASKFOLD_TEAM_PLANNING_REGRESSION !== "1") {
      throw new Error("Checklist regression requires planning");
    }
    const { loadTeamChecklistSchema, teamChecklistMigration } = await import(
      "./team-checklist-schema.mjs"
    );
    await loadTeamChecklistSchema(pg.raw);
    report.checklistMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamChecklistMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (process.env.TASKFOLD_TEAM_COMPLETION_REGRESSION === "1") {
    if (process.env.TASKFOLD_TEAM_CHECKLIST_REGRESSION !== "1") {
      throw new Error("Completion regression requires checklist schema");
    }
    const { loadTeamCompletionSchema, teamCompletionMigration } = await import(
      "./team-completion-schema.mjs"
    );
    await loadTeamCompletionSchema(pg.raw, { base: false });
    report.completionMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamCompletionMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (process.env.TASKFOLD_TEAM_REPEAT_REGRESSION === "1") {
    if (process.env.TASKFOLD_TEAM_CHECKLIST_REGRESSION !== "1") throw new Error("Repeat regression requires checklist schema");
    const sql = await readFile(new URL("../../supabase/migrations/20261024222451_team_task_repeat_edits.sql", import.meta.url), "utf8");
    await pg.raw(sql);
    report.repeatMigrationSHA256 = createHash("sha256").update(sql).digest("hex");
  }
  for (const [name, u] of Object.entries(people)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${
        lit(name + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${
        lit(u.id)
      });`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(people.owner.id)
    },'Synthetic team');` + Object.entries(people).filter(([k]) =>
      k !== "outsider"
    ).map(([k, u]) =>
      `insert into taskfold_private.team_members(team_id,user_id,role) values(${
        lit(team)
      },${lit(u.id)},${
        lit(k === "owner" ? "admin" : k === "guest" ? "guest" : "member")
      });`
    ).join(""),
  );
  for (const [p, v] of [[project, "team"], [hidden, "private"]]) {
    await pg.raw(
      `insert into public.projects(id,user_id,name) values(${lit(p)},${
        lit(people.owner.id)
      },'Synthetic project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
        lit(p)
      },${lit(team)},${lit(v)});`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${
      lit(people.viewer.id)
    },'viewer');insert into public.tasks(id,user_id,project_id,title,task_generation) values(${
      lit(task)
    },${lit(people.owner.id)},${lit(project)},'Original',${
      lit(generation)
    });insert into public.tasks(id,user_id,title) values(${lit(personal)},${
      lit(people.editor.id)
    },'Personal task');`,
  );
  if (process.env.TASKFOLD_CHILD_RECORDS_REGRESSION === "1") {
    const { loadChildTaskRecordsSchema, childTaskRecordsMigration } =
      await import(
        "./child-task-records-schema.mjs"
      );
    await loadChildTaskRecordsSchema(pg.raw);
    report.childRecordsMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + childTaskRecordsMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
    await pg.raw(
      `select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks order by id`,
    );
  }
  const run = (who, expression, opts = {}) => {
    const u = people[who];
    return pg.scalar(
      `begin;set application_name=${
        lit(opts.app ?? "team-edit-" + randomUUID().slice(0, 8))
      };create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated,anon,service_role;set local role ${
        opts.role ?? "authenticated"
      };set local request.jwt.claim.sub=${
        lit(u.id)
      };set local request.jwt.claims=${
        lit(
          JSON.stringify({
            sub: u.id,
            session_id: opts.session ?? u.session,
            ...opts.claims,
          }),
        )
      };do $r$begin begin ${
        opts.statement ??
          `insert into result values((${expression}),null,null);`
      }exception when others then insert into result values(null,sqlstate,left(sqlerrm,150));end;end$r$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`,
    );
  };
  const rpc = (who, b, opts) =>
    run(who, `public.taskfold_edit_team_task(${json(b)})`, opts);
  const row = () =>
    pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(task)}`);
  const body = async (changes = { title: "Edited" }, extra = {}) => {
    const t = await row();
    return {
      team_id: team,
      project_id: project,
      task_id: task,
      request_id: randomUUID(),
      task_generation: generation,
      base: {
        ...Object.fromEntries(Object.keys(changes).map((k) => [k, t[k]])),
        task_generation: generation,
        project_id: project,
        ...(Object.keys(changes).some((k) =>
            ["completed", "completed_at"].includes(k)
          )
          ? { completion_version: t.completion_version }
          : {}),
      },
      changes,
      ...extra,
    };
  };
  const draft = await body();
  check("edits default closed", (await rpc("editor", draft)).code, "PT503");
  await pg.raw(
    "update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true",
  );
  for (const who of ["viewer", "guest", "outsider"]) {
    check(
      who + " denied",
      (await rpc(who, draft)).code,
      who === "viewer" ? "42501" : "PT404",
    );
  }
  check(
    "anonymous denied",
    (await rpc("editor", draft, { role: "anon" })).code,
    "42501",
  );
  check(
    "service denied",
    (await rpc("editor", draft, { role: "service_role" })).code,
    "42501",
  );
  check(
    "unrecognized session denied",
    (await rpc("editor", draft, { session: randomUUID() })).code,
    "28000",
  );
  check(
    "forged editable metadata denied",
    (await rpc("viewer", draft, {
      claims: {
        user_metadata: { role: "admin" },
        app_metadata: { role: "admin" },
      },
    })).code,
    "42501",
  );
  let result = await rpc("editor", draft);
  check("editor can edit another creator task", result.code, null);
  check("creator remains intact", result.value.task.user_id, people.owner.id);
  check("title saved", result.value.task.title, "Edited");
  const nativeFixture = {
    body: draft,
    reply: result.value,
    account: people.editor.id,
  };
  check(
    "scope cleaned after success",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.team_task_edit_scope",
    ),
    0,
  );
  const next = await body({ description: "Later work" });
  check("independent field saved", (await rpc("owner", next)).code, null);
  result = await rpc("editor", draft);
  check("lost response retry accepted", result.code, null);
  check(
    "retry returns current row",
    result.value.task.description,
    "Later work",
  );
  check("retry marked replay", result.value.replayed, true);
  check(
    "nonce body cannot change",
    (await rpc("editor", { ...draft, changes: { title: "Forged" } })).code,
    "PT409",
  );
  check("nonce actor cannot change", (await rpc("owner", draft)).code, "PT409");
  check(
    "receipt has no task plaintext",
    await pg.scalar(
      `select to_jsonb(not exists(select 1 from taskfold_private.team_task_edits where to_jsonb(team_task_edits)::text like '%Edited%'))`,
    ),
    true,
  );
  for (
    const [k, value] of [
      ["project_id", hidden],
      ["assigned_to", people.editor.id],
      ["subtasks", []],
      ["attachments", []],
      ["comments", []],
      ["user_id", people.editor.id],
      ["task_generation", randomUUID()],
      ["source_metadata", {}],
    ].filter(([k]) =>
      (process.env.TASKFOLD_TEAM_PLANNING_REGRESSION !== "1" ||
        k !== "assigned_to") &&
      (process.env.TASKFOLD_TEAM_CHECKLIST_REGRESSION !== "1" ||
        k !== "subtasks")
    )
  ) {
    check(
      "separate " + k + " action required",
      (await rpc("editor", await body({ [k]: value }))).code,
      "22023",
    );
  }
  check(
    "large supported description accepted",
    (await rpc("editor", await body({ description: "x".repeat(30000) }))).code,
    null,
  );
  check(
    "unknown envelope field denied",
    (await rpc("editor", { ...await body(), unexpected: true })).code,
    "22023",
  );
  check(
    "receipt table hidden",
    (await run(
      "editor",
      "(select to_jsonb(count(*)) from taskfold_private.team_task_edits)",
    )).code,
    "42501",
  );
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(people.guest.id)},'editor')`,
  );
  check(
    "explicit guest editor accepted",
    (await rpc("guest", await body({ description: "Guest reviewed edit" })))
      .code,
    null,
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where user_id=${
      lit(people.guest.id)
    }`,
  );
  const stale = await body({ title: "Stale draft" });
  await pg.raw(
    `update public.tasks set title='Remote title' where id=${lit(task)}`,
  );
  check(
    "same field conflict retained",
    (await rpc("editor", stale)).code,
    "P0001",
  );
  check("conflict preserves remote title", (await row()).title, "Remote title");
  check(
    "scope cleaned after failure",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.team_task_edit_scope",
    ),
    0,
  );
  check(
    "no receipt for conflict",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_task_edits where request_id=${
        lit(stale.request_id)
      }`,
    ),
    0,
  );
  for (
    const change of [
      { title: "" },
      { title: null },
      { priority: 1.5 },
      { priority: 0 },
      { duration_minutes: 0 },
      { time_zone: "Unknown/Zone" },
      { title: { value: "Forged" } },
      { description: "x".repeat(129000) },
    ]
  ) {
    check(
      "invalid " + Object.keys(change)[0] + " " + JSON.stringify(change).length,
      (await rpc("editor", await body(change))).code,
      "22023",
    );
  }
  const wrong = await body();
  check(
    "wrong generation denied",
    (await rpc("editor", { ...wrong, task_generation: randomUUID() })).code,
    "PT409",
  );
  check(
    "personal task cannot enter team adapter",
    (await rpc("editor", { ...wrong, task_id: personal })).code,
    "PT409",
  );
  check(
    "wrong team denied",
    (await rpc("editor", { ...wrong, team_id: randomUUID() })).code,
    "PT404",
  );
  const missingBase = await body();
  delete missingBase.base.project_id;
  check(
    "frozen project baseline required",
    (await rpc("editor", missingBase)).code,
    "PT409",
  );
  const complete = await body({
    completed: true,
    completed_at: new Date().toISOString(),
  });
  const noVersion = structuredClone(complete);
  delete noVersion.base.completion_version;
  check(
    "completion version required",
    (await rpc("editor", noVersion)).code,
    "PT409",
  );
  result = await rpc("editor", complete);
  check("completion accepted", result.code, null);
  check(
    "completion increments version",
    result.value.task.completion_version,
    1,
  );
  check(
    "reopen accepted",
    (await rpc("editor", await body({ completed: false, completed_at: null })))
      .code,
    null,
  );
  const replayed = await rpc("editor", complete);
  check(
    "old complete retry does not recomplete",
    replayed.value.task.completed,
    false,
  );
  check(
    "old complete retry preserves revision",
    replayed.value.task.completion_version,
    2,
  );
  check(
    "stale new nonce completion cannot overwrite cycle",
    (await rpc("editor", { ...complete, request_id: randomUUID() })).code,
    "P0001",
  );
  for (const field of ["is_archived", "ancestor_archived"]) {
    await pg.raw(
      `update public.projects set ${field}=true where id=${lit(project)}`,
    );
    check(
      field + " denies edit",
      (await rpc("editor", await body())).code,
      "PT409",
    );
    await pg.raw(
      `update public.projects set ${field}=false where id=${lit(project)}`,
    );
  }
  await pg.raw(
    `update taskfold_private.teams set state='archived' where id=${lit(team)}`,
  );
  check(
    "archived team denies edit",
    (await rpc("editor", await body())).code,
    "PT503",
  );
  await pg.raw(
    `update taskfold_private.teams set state='active' where id=${lit(team)}`,
  );
  await pg.raw("update taskfold_private.team_config set enabled=false");
  check(
    "paused setup denies edit",
    (await rpc("editor", await body())).code,
    "PT503",
  );
  await pg.raw("update taskfold_private.team_config set enabled=true");
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(people.editor.id)},'viewer')`,
  );
  check(
    "demotion denies applied receipt replay",
    (await rpc("editor", draft)).code,
    "42501",
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where user_id=${
      lit(people.editor.id)
    }`,
  );
  check(
    "direct REST update still closed",
    (await run("editor", null, {
      statement: `with x as(update public.tasks set title='Bypass' where id=${
        lit(task)
      } returning id) insert into result select to_jsonb(count(*)),null,null from x;`,
    })).value,
    0,
  );
  check(
    "public legacy patch still closed",
    (await run(
      "editor",
      `to_jsonb(public.taskfold_patch_task(${lit(task)},${
        json((await body()).base)
      },'{"title":"Bypass"}'))`,
    )).code,
    process.env.TASKFOLD_TEAM_LIFECYCLE_REGRESSION === "1" ? "PT409" : "P0001",
  );
  check(
    "private scope cannot be forged",
    (await run("editor", null, {
      statement:
        `insert into taskfold_private.team_task_edit_scope values(txid_current(),${
          lit(team)
        },${lit(project)},${lit(task)},${lit(generation)},${
          lit(people.editor.id)
        });`,
    })).code,
    "42501",
  );
  check(
    "private merger cannot be called",
    (await run(
      "editor",
      `to_jsonb(taskfold_private.team_task_merge(${lit(task)},'{}','{}'))`,
    )).code,
    "42501",
  );
  const personalRow = await pg.scalar(
    `select to_jsonb(t) from public.tasks t where id=${lit(personal)}`,
  );
  check(
    "personal merge regression",
    (await run(
      "editor",
      `to_jsonb(public.taskfold_patch_task(${lit(personal)},${
        json({
          title: "Personal task",
          task_generation: personalRow.task_generation,
        })
      },'{"title":"Personal edited"}'))`,
    )).code,
    null,
  );
  const concurrent = await body({ title: "After wait" }),
    app = "team-edit-revoke";
  let holder = await pg.hold(
    `select id from taskfold_private.teams where id=${lit(team)} for update`,
  );
  const pending = rpc("editor", concurrent, { app });
  await pg.waitForLock(app, holder.pid);
  await holder.release(
    "commit",
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(people.editor.id)},'viewer')`,
  );
  check(
    "permission revoked while waiting denies edit",
    (await pending).code,
    "42501",
  );
  check("waiting draft preserved remote", (await row()).title, "Remote title");
  await pg.raw(
    `delete from taskfold_private.team_project_grants where user_id=${
      lit(people.editor.id)
    }`,
  );
  holder = await pg.hold(
    `select id from public.tasks where id=${lit(task)} for update`,
  );
  const changed = await body({ title: "Concurrent draft" });
  const conflict = rpc("editor", changed, { app: "team-edit-conflict" });
  await pg.waitForLock("team-edit-conflict", holder.pid);
  await holder.release(
    "commit",
    `update public.tasks set title='Concurrent remote' where id=${lit(task)}`,
  );
  check("task changed while waiting conflicts", (await conflict).code, "P0001");
  const retained = randomUUID();
  await pg.raw(
    `insert into public.tasks(id,user_id,project_id,title) values(${
      lit(retained)
    },${lit(people.outsider.id)},${
      lit(project)
    },'Retained creator task');delete from auth.users where id=${
      lit(people.outsider.id)
    }`,
  );
  const retainedRow = await pg.scalar(
    `select to_jsonb(t) from public.tasks t where id=${lit(retained)}`,
  );
  const retainedEdit = {
    team_id: team,
    project_id: project,
    task_id: retained,
    request_id: randomUUID(),
    task_generation: retainedRow.task_generation,
    base: {
      task_generation: retainedRow.task_generation,
      project_id: project,
      title: retainedRow.title,
    },
    changes: { title: "Retained task edited" },
  };
  const retainedReply = await rpc("editor", retainedEdit);
  check("removed creator work remains editable", retainedReply.code, null);
  check(
    "removed creator UUID remains",
    retainedReply.value.task.user_id,
    people.outsider.id,
  );
  if (process.env.TASKFOLD_TEAM_PLANNING_REGRESSION === "1") {
    const { checkTeamPlanning } = await import("./team-planning-checks.mjs");
    nativeFixture.planning = await checkTeamPlanning({
      pg,
      check,
      rpc,
      row,
      body,
      people,
      team,
      project,
      hidden,
      task,
    });
  }
  if (process.env.TASKFOLD_TEAM_CHECKLIST_REGRESSION === "1") {
    const { checkTeamChecklist } = await import("./team-checklist-checks.mjs");
    nativeFixture.checklist = await checkTeamChecklist({
      pg,
      check,
      rpc,
      run,
      row,
      body,
      people,
      team,
      project,
      task,
    });
  }
  if (process.env.TASKFOLD_CHILD_RECORDS_REGRESSION === "1") {
    check(
      "adopted team roots retain exact current source",
      await pg.scalar(`select to_jsonb(not exists(
      select 1 from taskfold_private.child_task_projections p join public.tasks t on t.id=p.task_id
      where p.source_tree is distinct from coalesce(t.subtasks,'null'::jsonb) or p.task_generation is distinct from t.task_generation))`),
      true,
    );
    check(
      "adopted team records match current decoded source",
      await pg.scalar(`select to_jsonb(not exists(
      select 1 from taskfold_private.child_task_projections p where p.state='ready' and
      (select coalesce(jsonb_agg(n order by n->>'key' collate "C"),'[]') from jsonb_array_elements(taskfold_private.decode_child_task_tree(p.source_tree)->'nodes') n)
      is distinct from (select coalesce(jsonb_agg(jsonb_build_object('key',r.node_key,'parent',r.parent_key,'position',r.sibling_order,'path',r.identity_path,'fields',r.fields,'children_kind',r.children_kind) order by r.node_key),'[]') from taskfold_private.child_task_records r where r.task_id=p.task_id)))`),
      true,
    );
  }
  report.advisors = await pg.advisors();
  check(
    "no new security performance warnings",
    report.advisors.result.filter((x) =>
      ["WARN", "ERROR"].includes(x.level) && x.name !== "auth_rls_initplan"
    ),
    [],
  );
  report.containerRemoved = await pg.close();
  pg = null;
  report.checkCount = Object.keys(report.checks).length;
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
  if (process.argv[3]) {
    await writeFile(
      process.argv[3],
      JSON.stringify(nativeFixture, null, 2) + "\n",
    );
  }
  console.log(
    JSON.stringify({
      checks: report.checkCount,
      containerRemoved: report.containerRemoved,
    }),
  );
} finally {
  if (pg) await pg.close();
}
